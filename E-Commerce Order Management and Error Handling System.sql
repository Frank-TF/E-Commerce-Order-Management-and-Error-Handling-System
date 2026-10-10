-- =====================================================================
-- EASY E-COMMERCE EXAMPLE: FUNCTION + TRIGGERS + PROCEDURE + EXCEPTIONS
-- (Oracle SQL Developer / SQL*Plus). Run from top to bottom.
--
-- The idea in plain words:
--   * A customer orders a product.
--   * The FUNCTION checks how much stock is left.
--   * The PROCEDURE places the order and handles any problems.
--   * The TRIGGERS run by themselves: they give the order a number,
--     reduce the stock, and stop the stock from going below zero.
--   * EXCEPTIONS are how we deal with errors without crashing.
-- =====================================================================
SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------
-- STEP 1: Create tables and sample data
-- ---------------------------------------------------------------------
CREATE TABLE products (
    product_id  NUMBER PRIMARY KEY,
    name        VARCHAR2(50),
    price       NUMBER,
    stock_qty   NUMBER
);

CREATE TABLE orders (
    order_id     NUMBER PRIMARY KEY,
    product_id   NUMBER,
    qty          NUMBER,
    total_amount NUMBER,
    order_date   DATE
);

-- This table keeps a record of every error
CREATE TABLE error_log (
    log_id     NUMBER PRIMARY KEY,
    error_msg  VARCHAR2(200),
    logged_at  DATE DEFAULT SYSDATE
);

-- Sequences make automatic numbers (1000, 1001, 1002 ...)
CREATE SEQUENCE seq_order START WITH 1000;
CREATE SEQUENCE seq_error START WITH 1;

INSERT INTO products VALUES (101, 'Wireless Mouse', 500, 10);
INSERT INTO products VALUES (102, 'Keyboard',       900, 2);
COMMIT;

-- ---------------------------------------------------------------------
-- STEP 2: FUNCTION  (it gives back one value)
-- Returns the stock of a product. Returns -1 if the product is not found.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_stock (p_product_id IN NUMBER)
RETURN NUMBER
IS
    v_stock NUMBER;
BEGIN
    SELECT stock_qty INTO v_stock
      FROM products
     WHERE product_id = p_product_id;

    RETURN v_stock;

EXCEPTION
    WHEN NO_DATA_FOUND THEN        -- the product does not exist
        RETURN -1;
END get_stock;
/

-- ---------------------------------------------------------------------
-- STEP 3: TRIGGERS  (they run automatically when data changes)
-- ---------------------------------------------------------------------

-- Trigger 1: Before a new order is saved, give it an order number and date.
CREATE OR REPLACE TRIGGER trg_order_before_insert
BEFORE INSERT ON orders
FOR EACH ROW
BEGIN
    :NEW.order_id   := seq_order.NEXTVAL;   -- :NEW = the new row being added
    :NEW.order_date := SYSDATE;
END;
/

-- Trigger 2: After an order is saved, reduce the product stock.
CREATE OR REPLACE TRIGGER trg_order_after_insert
AFTER INSERT ON orders
FOR EACH ROW
BEGIN
    UPDATE products
       SET stock_qty = stock_qty - :NEW.qty
     WHERE product_id = :NEW.product_id;
END;
/

-- Trigger 3: Never allow stock to become negative.
CREATE OR REPLACE TRIGGER trg_product_before_update
BEFORE UPDATE ON products
FOR EACH ROW
BEGIN
    IF :NEW.stock_qty < 0 THEN
        RAISE_APPLICATION_ERROR(-20030, 'Stock cannot be less than zero.');
    END IF;
END;
/

-- ---------------------------------------------------------------------
-- STEP 4: PROCEDURE to save errors
-- AUTONOMOUS_TRANSACTION means: save this record on its own,
-- so it is not lost even if the order is cancelled (rolled back).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE log_error (p_msg IN VARCHAR2)
AS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO error_log (log_id, error_msg)
    VALUES (seq_error.NEXTVAL, p_msg);
    COMMIT;
END;
/

-- ---------------------------------------------------------------------
-- STEP 5: MAIN PROCEDURE - place an order
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE place_order (
    p_product_id IN NUMBER,
    p_qty        IN NUMBER
) AS
    -- Our own exceptions (for our own business rules)
    e_bad_qty          EXCEPTION;
    e_product_missing  EXCEPTION;
    e_out_of_stock     EXCEPTION;

    v_stock NUMBER;
    v_price NUMBER;
    v_total NUMBER;
BEGIN
    -- Rule 1: quantity must be more than zero
    IF p_qty <= 0 THEN
        RAISE e_bad_qty;
    END IF;

    -- Rule 2: product must exist (we use our function)
    v_stock := get_stock(p_product_id);
    IF v_stock = -1 THEN
        RAISE e_product_missing;
    END IF;

    -- Rule 3: there must be enough stock
    IF v_stock < p_qty THEN
        RAISE e_out_of_stock;
    END IF;

    -- All good: calculate total and save the order.
    -- The triggers will add the order number and reduce the stock.
    SELECT price INTO v_price FROM products WHERE product_id = p_product_id;
    v_total := v_price * p_qty;

    INSERT INTO orders (product_id, qty, total_amount)
    VALUES (p_product_id, p_qty, v_total);

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Order placed. Total = ' || v_total);

EXCEPTION
    -- Each WHEN block handles one kind of problem
    WHEN e_bad_qty THEN
        ROLLBACK;
        log_error('Bad quantity: ' || p_qty);
        RAISE_APPLICATION_ERROR(-20001, 'Quantity must be more than zero.');

    WHEN e_product_missing THEN
        ROLLBACK;
        log_error('Product not found: ' || p_product_id);
        RAISE_APPLICATION_ERROR(-20002, 'Product does not exist.');

    WHEN e_out_of_stock THEN
        ROLLBACK;
        log_error('Out of stock. Product ' || p_product_id || ', wanted ' || p_qty);
        RAISE_APPLICATION_ERROR(-20003, 'Not enough stock. Only ' || v_stock || ' left.');

    WHEN OTHERS THEN               -- any other unexpected error
        ROLLBACK;
        log_error('Unexpected error: ' || SQLERRM);
        RAISE;                     -- show the real error to the caller
END place_order;
/

-- ---------------------------------------------------------------------
-- STEP 6: TEST EVERYTHING
-- ---------------------------------------------------------------------

-- Test the function
BEGIN
    DBMS_OUTPUT.PUT_LINE('Stock of product 101: ' || get_stock(101));
    DBMS_OUTPUT.PUT_LINE('Stock of product 999: ' || get_stock(999) || ' (-1 means not found)');
END;
/

-- Test the procedure: one good order and three bad ones
BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Test 1: good order');
    place_order(101, 2);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Test 2: quantity is zero');
    place_order(101, 0);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Test 3: product does not exist');
    place_order(999, 1);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Test 4: not enough stock');
    place_order(102, 5);
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

-- Test the stock trigger directly
BEGIN
    DBMS_OUTPUT.PUT_LINE('--- Test 5: set stock to a negative number');
    UPDATE products SET stock_qty = -5 WHERE product_id = 101;
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
END;
/

-- ---------------------------------------------------------------------
-- STEP 7: LOOK AT THE RESULTS
-- Product 101 should now have stock 8 (10 - 2).
-- ---------------------------------------------------------------------
SELECT * FROM products;
SELECT * FROM orders;
SELECT * FROM error_log;

-- ---------------------------------------------------------------------
-- OPTIONAL: To run the file again, remove everything first
-- (remove the -- in front of each line, then run them)
-- ---------------------------------------------------------------------
-- DROP TABLE orders;
-- DROP TABLE products;
-- DROP TABLE error_log;
-- DROP SEQUENCE seq_order;
-- DROP SEQUENCE seq_error;
-- DROP FUNCTION get_stock;
-- DROP PROCEDURE place_order;
-- DROP PROCEDURE log_error;
