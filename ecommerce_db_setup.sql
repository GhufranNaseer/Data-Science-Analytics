-- ============================================================================
-- PROJECT: E-Commerce Sales Analysis (PostgreSQL Star Schema Design)
-- COURSE: Data Science and Analytics - Batch 7 (Final Project Solution)
-- DESIGNED BY: Senior Data Architect, Data Engineer & BI Developer
-- DESCRIPTION: Highly optimized database schema, data cleaning, migration
--              ETL, performance indexing, and DirectQuery configuration.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- STEP 1: CREATE STAGING TABLE
-- Purpose: This table acts as a landing zone for raw Excel/CSV imports before ETL.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS staging_sales CASCADE;

CREATE TABLE staging_sales (
    row_id INT,
    order_id VARCHAR(50),
    year INT,
    order_date DATE,
    ship_date DATE,
    ship_mode VARCHAR(50),
    customer_id VARCHAR(50),
    customer_name VARCHAR(150),
    segment VARCHAR(50),
    country VARCHAR(100),
    city VARCHAR(100),
    state VARCHAR(100),
    postal_code INT,
    region VARCHAR(50),
    product_id VARCHAR(50),
    category VARCHAR(100),
    sub_category VARCHAR(100),
    product_name VARCHAR(255),
    sales NUMERIC(12, 4),
    quantity INT,
    discount NUMERIC(5, 2),
    profit NUMERIC(12, 4)
);

-- ----------------------------------------------------------------------------
-- STEP 2: BULK LOADING DATA STRATEGY (INSERT / COPY Commands)
-- ----------------------------------------------------------------------------
/*
   METHOD A: USING THE PostgreSQL COPY COMMAND (Highly Recommended for Performance)
   Run this command in psql or pgAdmin to bulk import the CSV version of the dataset:
   
   COPY staging_sales(row_id, order_id, year, order_date, ship_date, ship_mode, 
                      customer_id, customer_name, segment, country, city, state, 
                      postal_code, region, product_id, category, sub_category, 
                      product_name, sales, quantity, discount, profit)
   FROM 'C:/path_to_your_project/Ecommerce_Sales_Analysis.csv'
   DELIMITER ',' 
   CSV HEADER;
   
   METHOD B: USING PYTHON (pandas.to_sql) FOR AUTOMATED ETL
   This is our automated method implemented in the Python script:
   
   import pandas as pd
   from sqlalchemy import create_engine
   
   engine = create_engine('postgresql://username:password@localhost:5432/ecommerce_db')
   df = pd.read_excel('Ecommerce_Sales_Analysis.xlsx', sheet_name='Data')
   df.to_sql('staging_sales', engine, if_exists='replace', index=False)
*/

-- ----------------------------------------------------------------------------
-- STEP 3: DATA CLEANING & STANDARDIZATION IN STAGING
-- ----------------------------------------------------------------------------
-- Standardizing customer segments to capitalized, trimming whitespaces,
-- handling potential missing postal codes, and ensuring non-null primary attributes.
BEGIN;

-- A. Trim whitespace from text fields
UPDATE staging_sales 
SET customer_name = TRIM(customer_name),
    customer_id = TRIM(customer_id),
    product_name = TRIM(product_name),
    product_id = TRIM(product_id),
    city = TRIM(city),
    state = TRIM(state),
    country = TRIM(country);

-- B. Handle Missing Postal Codes (if any exist, standardizing to a default value e.g., 0)
UPDATE staging_sales 
SET postal_code = 99999 
WHERE postal_code IS NULL;

-- C. Standardize Category names (e.g., lower casing and then Initcap)
UPDATE staging_sales 
SET category = INITCAP(TRIM(category)),
    sub_category = INITCAP(TRIM(sub_category));

-- D. De-duplication: Delete exact duplicate rows in staging if they exist, keeping only the lowest row_id
DELETE FROM staging_sales a
USING staging_sales b
WHERE a.row_id > b.row_id 
  AND a.order_id = b.order_id 
  AND a.customer_id = b.customer_id 
  AND a.product_id = b.product_id
  AND a.sales = b.sales;

COMMIT;

-- ----------------------------------------------------------------------------
-- STEP 4: CREATE STAR SCHEMA DIMENSIONAL TABLES
-- ----------------------------------------------------------------------------

-- A. Customer Dimension
DROP TABLE IF EXISTS dim_customers CASCADE;
CREATE TABLE dim_customers (
    customer_id VARCHAR(50) PRIMARY KEY,
    customer_name VARCHAR(150) NOT NULL,
    segment VARCHAR(50) NOT NULL
);

-- B. Location Dimension
DROP TABLE IF EXISTS dim_locations CASCADE;
CREATE TABLE dim_locations (
    postal_code INT PRIMARY KEY,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(100) NOT NULL,
    country VARCHAR(100) NOT NULL,
    region VARCHAR(50) NOT NULL
);

-- C. Product Dimension
DROP TABLE IF EXISTS dim_products CASCADE;
CREATE TABLE dim_products (
    product_id VARCHAR(50) PRIMARY KEY,
    product_name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    sub_category VARCHAR(100) NOT NULL
);

-- D. Sales Fact Table
DROP TABLE IF EXISTS fact_sales CASCADE;
CREATE TABLE fact_sales (
    row_id INT PRIMARY KEY,
    order_id VARCHAR(50) NOT NULL,
    order_date DATE NOT NULL,
    ship_date DATE NOT NULL,
    ship_mode VARCHAR(50) NOT NULL,
    customer_id VARCHAR(50) REFERENCES dim_customers(customer_id),
    postal_code INT REFERENCES dim_locations(postal_code),
    product_id VARCHAR(50) REFERENCES dim_products(product_id),
    sales NUMERIC(12, 4) NOT NULL CHECK (sales >= 0),
    quantity INT NOT NULL CHECK (quantity > 0),
    discount NUMERIC(5, 2) NOT NULL CHECK (discount >= 0 AND discount <= 1.00),
    profit NUMERIC(12, 4) NOT NULL
);

-- ----------------------------------------------------------------------------
-- STEP 5: POPULATE STAR SCHEMA (ETL / DATA MIGRATION)
-- ----------------------------------------------------------------------------
BEGIN;

-- A. Populate dim_customers (Using distinct combinations, keeping the latest info if changes exist)
INSERT INTO dim_customers (customer_id, customer_name, segment)
SELECT DISTINCT customer_id, customer_name, segment
FROM staging_sales
ON CONFLICT (customer_id) 
DO UPDATE SET 
    customer_name = EXCLUDED.customer_name,
    segment = EXCLUDED.segment;

-- B. Populate dim_locations (Using distinct combinations of postal codes)
INSERT INTO dim_locations (postal_code, city, state, country, region)
SELECT DISTINCT postal_code, city, state, country, region
FROM staging_sales
ON CONFLICT (postal_code) 
DO UPDATE SET 
    city = EXCLUDED.city,
    state = EXCLUDED.state,
    country = EXCLUDED.country,
    region = EXCLUDED.region;

-- C. Populate dim_products (Ensure one product_id maps to a single product name/category)
INSERT INTO dim_products (product_id, product_name, category, sub_category)
SELECT DISTINCT ON (product_id) product_id, product_name, category, sub_category
FROM staging_sales
ORDER BY product_id, row_id DESC
ON CONFLICT (product_id) 
DO UPDATE SET 
    product_name = EXCLUDED.product_name,
    category = EXCLUDED.category,
    sub_category = EXCLUDED.sub_category;

-- D. Populate fact_sales
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

COMMIT;

-- ----------------------------------------------------------------------------
-- STEP 6: INDEXING FOR ENTERPRISE QUERY PERFORMANCE
-- ----------------------------------------------------------------------------
-- Indexes on Foreign Keys to dramatically improve JOIN performance (vital for Power BI DirectQuery)
CREATE INDEX idx_fact_sales_customer ON fact_sales(customer_id);
CREATE INDEX idx_fact_sales_location ON fact_sales(postal_code);
CREATE INDEX idx_fact_sales_product ON fact_sales(product_id);

-- Composite Indexes on commonly filtered analytical dimensions (Dates, Category, Regions)
CREATE INDEX idx_fact_sales_dates ON fact_sales(order_date, ship_date);
CREATE INDEX idx_dim_products_category ON dim_products(category, sub_category);
CREATE INDEX idx_dim_locations_region ON dim_locations(region, state);

-- Covering Index for standard financial aggregations
CREATE INDEX idx_fact_sales_financials ON fact_sales(order_date) INCLUDE (sales, profit, quantity);

-- ----------------------------------------------------------------------------
-- STEP 7: CONNECTING POWER BI USING DIRECTQUERY MODE
-- ----------------------------------------------------------------------------
/*
   Power BI DirectQuery connects directly to the PostgreSQL database in real-time,
   meaning the data is queried directly in PostgreSQL instead of being cached in Power BI's memory.
   
   To establish the connection:
   
   1. Install PostgreSQL Npgsql provider (Npgsql GAC installer) on the Power BI Desktop client machine.
   2. Open Power BI Desktop -> Click 'Get Data' -> Select 'PostgreSQL database'.
   3. Provide Connection Details:
      - Server: localhost:5432 (or server IP)
      - Database: ecommerce_db
      - Data Connectivity Mode: Choose 'DirectQuery'
   4. Enter Credentials: Input your PostgreSQL database Username and Password.
   5. Select Tables:
      - Check `dim_customers`, `dim_locations`, `dim_products`, and `fact_sales`.
      - Click 'Load'.
   6. Relationship Configuration (Model View):
      - Validate that Power BI has auto-detected the 1-to-Many relationships.
      - Ensure 'Cross filter direction' is set to 'Single' and 'Assume Referential Integrity' is checked (since we enforced Foreign Keys in DDL).
      
   BENEFITS OF DIRECTQUERY ON THIS SCHEMA:
   *   No data size limitation on the BI client side.
   *   Utilizes the indexing we created (e.g., idx_fact_sales_financials) for real-time aggregations.
   *   Real-time reporting dashboard.
*/

-- ----------------------------------------------------------------------------
-- STEP 8: ANALYTICAL VALIDATION QUERY (Sample test for DirectQuery simulation)
-- ----------------------------------------------------------------------------
SELECT 
    p.category,
    SUM(f.sales) AS total_sales,
    SUM(f.profit) AS total_profit,
    ROUND((SUM(f.profit) / SUM(f.sales)) * 100, 2) AS profit_margin_pct,
    COUNT(DISTINCT f.order_id) AS total_orders
FROM fact_sales f
JOIN dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY total_sales DESC;
