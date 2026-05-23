import os
import sys
import pandas as pd
from sqlalchemy import create_engine, text

# Database Connection Configurations
DB_HOST = "localhost"
DB_PORT = "5432"
DB_NAME = "ecommerce_db"
DB_USER = "postgres"  # Standard default, will ask user if different

print("=" * 60)
print("E-COMMERCE SALES DATABASE LOADER & ETL PIPELINE")
print("=" * 60)

# Check if the excel file exists
excel_file = "Ecommerce_Sales_Analysis.xlsx"
if not os.path.exists(excel_file):
    print(f"Error: {excel_file} not found in the current directory!")
    print("Please run 'download_and_inspect.py' first to download the dataset.")
    sys.exit(1)

# Ask for PostgreSQL credentials
print(f"\nPlease enter your PostgreSQL credentials to connect to '{DB_NAME}':")
user = input(f"Username [{DB_USER}]: ").strip() or DB_USER
password = input("Password (hidden / type standard password): ").strip()
host = input(f"Host [{DB_HOST}]: ").strip() or DB_HOST
port = input(f"Port [{DB_PORT}]: ").strip() or DB_PORT

# Create connection engine
conn_string = f"postgresql://{user}:{password}@{host}:{port}/{DB_NAME}"
try:
    print("\nConnecting to database...")
    engine = create_engine(conn_string)
    # Test connection
    with engine.connect() as conn:
        result = conn.execute(text("SELECT version();")).fetchone()
        print(f"Connected successfully to: {result[0]}")
except Exception as e:
    print("\nDatabase connection failed!")
    print(f"Error Details: {e}")
    print("\nPlease verify:")
    print("1. PostgreSQL is running.")
    print(f"2. Database '{DB_NAME}' has been created.")
    print("3. Your username and password are correct.")
    sys.exit(1)

# Load the Excel file
try:
    print(f"\nLoading '{excel_file}' sheet 'Data' into memory (this may take a few seconds)...")
    df = pd.read_excel(excel_file, sheet_name="Data")
    print(f"Loaded {len(df)} rows and {len(df.columns)} columns.")
except Exception as e:
    print(f"Error loading Excel file: {e}")
    sys.exit(1)

# Standardize column names to snake_case for staging_sales table
print("\nStandardizing column names for database mapping...")
# Replace spaces/hyphens with underscores, convert to lowercase
column_mapping = {col: col.strip().lower().replace(" ", "_").replace("-", "_") for col in df.columns}
df = df.rename(columns=column_mapping)

print("Mapped columns:")
for orig, new in column_mapping.items():
    print(f"  - '{orig}' -> '{new}'")

# Write DataFrame to staging_sales table
try:
    print("\nUploading raw data to 'staging_sales' table (replacing if exists)...")
    df.to_sql("staging_sales", engine, if_exists="replace", index=False)
    print("Data uploaded to staging table successfully!")
except Exception as e:
    print(f"Error uploading to database: {e}")
    print("Please make sure you have 'sqlalchemy' and 'psycopg2' installed (pip install sqlalchemy psycopg2-binary).")
    sys.exit(1)

# Run ETL and star schema population queries
etl_steps = [
    # STEP A: Data Cleaning & De-duplication in Staging
    ("A. Cleaning & standardizing staging data...", """
        BEGIN;
        
        -- Trim whitespace from text fields
        UPDATE staging_sales 
        SET customer_name = TRIM(customer_name),
            customer_id = TRIM(customer_id),
            product_name = TRIM(product_name),
            product_id = TRIM(product_id),
            city = TRIM(city),
            state = TRIM(state),
            country = TRIM(country);

        -- Handle Missing Postal Codes
        UPDATE staging_sales 
        SET postal_code = 99999 
        WHERE postal_code IS NULL;

        -- Standardize Category names
        UPDATE staging_sales 
        SET category = INITCAP(TRIM(category)),
            sub_category = INITCAP(TRIM(sub_category));

        -- De-duplication
        DELETE FROM staging_sales a
        USING staging_sales b
        WHERE a.row_id > b.row_id 
          AND a.order_id = b.order_id 
          AND a.customer_id = b.customer_id 
          AND a.product_id = b.product_id
          AND a.sales = b.sales;

        COMMIT;
    """),
    
    # STEP B: Populate Customers Dimension
    ("B. Populating 'dim_customers'...", """
        INSERT INTO dim_customers (customer_id, customer_name, segment)
        SELECT DISTINCT customer_id, customer_name, segment
        FROM staging_sales
        ON CONFLICT (customer_id) 
        DO UPDATE SET 
            customer_name = EXCLUDED.customer_name,
            segment = EXCLUDED.segment;
    """),
    
    # STEP C: Populate Locations Dimension
    ("C. Populating 'dim_locations'...", """
        INSERT INTO dim_locations (postal_code, city, state, country, region)
        SELECT DISTINCT postal_code, city, state, country, region
        FROM staging_sales
        ON CONFLICT (postal_code) 
        DO UPDATE SET 
            city = EXCLUDED.city,
            state = EXCLUDED.state,
            country = EXCLUDED.country,
            region = EXCLUDED.region;
    """),
    
    # STEP D: Populate Products Dimension
    ("D. Populating 'dim_products'...", """
        INSERT INTO dim_products (product_id, product_name, category, sub_category)
        SELECT DISTINCT ON (product_id) product_id, product_name, category, sub_category
        FROM staging_sales
        ORDER BY product_id, row_id DESC
        ON CONFLICT (product_id) 
        DO UPDATE SET 
            product_name = EXCLUDED.product_name,
            category = EXCLUDED.category,
            sub_category = EXCLUDED.sub_category;
    """),
    
    # STEP E: Populate Fact Table (fact_sales)
    ("E. Populating 'fact_sales'...", """
        TRUNCATE fact_sales CASCADE; -- Clear existing old fact data
        
        INSERT INTO fact_sales (row_id, order_id, order_date, ship_date, ship_mode, customer_id, postal_code, product_id, sales, quantity, discount, profit)
        SELECT 
            row_id, 
            order_id, 
            order_date, 
            ship_date, 
            ship_mode, 
            customer_id, 
            postal_code, 
            product_id, 
            sales, 
            quantity, 
            discount, 
            profit
        FROM staging_sales;
    """),
    
    # STEP F: Create Performance Indexes
    ("F. Creating enterprise query performance indexes...", """
        CREATE INDEX IF NOT EXISTS idx_fact_sales_customer ON fact_sales(customer_id);
        CREATE INDEX IF NOT EXISTS idx_fact_sales_location ON fact_sales(postal_code);
        CREATE INDEX IF NOT EXISTS idx_fact_sales_product ON fact_sales(product_id);
        CREATE INDEX IF NOT EXISTS idx_fact_sales_dates ON fact_sales(order_date, ship_date);
        CREATE INDEX IF NOT EXISTS idx_dim_products_category ON dim_products(category, sub_category);
        CREATE INDEX IF NOT EXISTS idx_dim_locations_region ON dim_locations(region, state);
    """)
]

print("\n" + "="*50)
print("RUNNING ETL PIPELINE (POPULATING STAR SCHEMA)")
print("="*50)

with engine.begin() as conn:
    for description, query in etl_steps:
        print(description)
        try:
            conn.execute(text(query))
        except Exception as e:
            print(f"  [ERROR] Failed during: {description}")
            print(f"  Details: {e}")
            sys.exit(1)

print("\nETL Pipeline completed successfully! All dimensional and fact tables populated.")

# Running verification query to confirm
print("\n" + "="*50)
print("RUNNING VERIFICATION QUERY")
print("="*50)

verification_query = """
SELECT 
    p.category,
    COUNT(f.row_id) AS total_rows,
    SUM(f.sales) AS total_sales,
    SUM(f.profit) AS total_profit,
    ROUND((SUM(f.profit) / SUM(f.sales)) * 100, 2) AS profit_margin_pct
FROM fact_sales f
JOIN dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY total_sales DESC;
"""

try:
    with engine.connect() as conn:
        results = conn.execute(text(verification_query)).fetchall()
        print(f"{'Category':<20} | {'Rows':<6} | {'Total Sales':<15} | {'Total Profit':<15} | {'Margin %':<8}")
        print("-" * 72)
        for row in results:
            print(f"{row[0]:<20} | {row[1]:<6} | ${row[2]:,.2f:<14} | ${row[3]:,.2f:<14} | {row[4]}%")
except Exception as e:
    print(f"Error running verification query: {e}")

print("\n" + "="*60)
print("SUCCESS: Your database is fully loaded and ready for Power BI!")
print("="*60)
