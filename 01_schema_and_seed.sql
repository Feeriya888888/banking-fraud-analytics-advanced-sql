-- ============================================================================
-- 01_schema_and_seed.sql
-- DDL схемы розничного банкинга, индексы и генерация синтетических данных
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS bank;

-- 1. Справочник клиентов
CREATE TABLE bank.customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    segment VARCHAR(20) NOT NULL CHECK (segment IN ('Mass', 'Affluent', 'VIP')),
    home_city VARCHAR(50) NOT NULL,
    registered_at DATE NOT NULL
);

-- 2. Счета и карты
CREATE TABLE bank.accounts (
    account_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES bank.customers(customer_id),
    card_number_mask VARCHAR(19) NOT NULL,
    currency CHAR(3) DEFAULT 'RUB',
    opened_at DATE NOT NULL,
    status VARCHAR(15) DEFAULT 'ACTIVE'
);

-- 3. Таблица транзакций (партиционированная по месяцам для масштабируемости)
CREATE TABLE bank.transactions (
    tx_id BIGSERIAL,
    account_id INT NOT NULL REFERENCES bank.accounts(account_id),
    tx_timestamp TIMESTAMP NOT NULL,
    amount NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    merchant_category VARCHAR(40) NOT NULL,
    tx_city VARCHAR(50) NOT NULL,
    tx_type VARCHAR(20) NOT NULL CHECK (tx_type IN ('POS_PURCHASE', 'ONLINE_PAYMENT', 'P2P_TRANSFER', 'ATM_WITHDRAWAL')),
    is_declined BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (tx_id, tx_timestamp)
) PARTITION BY RANGE (tx_timestamp);

-- Создание партиций на 2026 год
CREATE TABLE bank.transactions_2026_q1 PARTITION OF bank.transactions
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE bank.transactions_2026_q2 PARTITION OF bank.transactions
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE bank.transactions_2026_q3 PARTITION OF bank.transactions
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE bank.transactions_2026_q4 PARTITION OF bank.transactions
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

-- 4. Таблица P2P переводов между счетами (для графового поиска через RECURSIVE CTE)
CREATE TABLE bank.p2p_transfers (
    transfer_id SERIAL PRIMARY KEY,
    from_account_id INT NOT NULL REFERENCES bank.accounts(account_id),
    to_account_id INT NOT NULL REFERENCES bank.accounts(account_id),
    transfer_time TIMESTAMP NOT NULL,
    amount NUMERIC(14, 2) NOT NULL
);

-- Покрывающие индексы для ускорения аналитических и антифрод-запросов
CREATE INDEX idx_tx_account_time ON bank.transactions (account_id, tx_timestamp) INCLUDE (amount, tx_city, is_declined);
CREATE INDEX idx_tx_category ON bank.transactions (merchant_category, tx_timestamp);
CREATE INDEX idx_p2p_from_time ON bank.p2p_transfers (from_account_id, transfer_time);

-- ============================================================================
-- ГЕНЕРАЦИЯ РЕАЛИСТИЧНЫХ ДАННЫХ (SEED)
-- ============================================================================

-- Генерация 500 клиентов
INSERT INTO bank.customers (full_name, segment, home_city, registered_at)
SELECT 
    'Client_' || gs,
    CASE WHEN gs % 20 = 0 THEN 'VIP' WHEN gs % 5 = 0 THEN 'Affluent' ELSE 'Mass' END,
    (ARRAY['Moscow', 'Saint Petersburg', 'Kazan', 'Novosibirsk', 'Yekaterinburg', 'Sochi'])[1 + (gs % 6)],
    DATE '2026-01-01' + ((gs * 3) % 180)
FROM generate_series(1, 500) AS gs;

-- Генерация 650 счетов
INSERT INTO bank.accounts (customer_id, card_number_mask, opened_at)
SELECT 
    1 + (gs % 500),
    '4276 **** **** ' || LPAD((1000 + gs)::TEXT, 4, '0'),
    DATE '2026-01-01' + ((gs * 2) % 180)
FROM generate_series(1, 650) AS gs;

-- Генерация 15 000 обычных транзакций
INSERT INTO bank.transactions (account_id, tx_timestamp, amount, merchant_category, tx_city, tx_type, is_declined)
SELECT 
    1 + (gs % 650),
    TIMESTAMP '2026-01-05 08:00:00' + (gs * INTERVAL '25 minutes'),
    ROUND((150 + (RANDOM() * 12000))::NUMERIC, 2),
    (ARRAY['Supermarkets', 'Restaurants', 'Electronics', 'Travel', 'Fuel', 'Pharmacies', 'Digital_Services'])[1 + (gs % 7)],
    (ARRAY['Moscow', 'Saint Petersburg', 'Kazan', 'Novosibirsk', 'Yekaterinburg', 'Sochi'])[1 + (gs % 6)],
    (ARRAY['POS_PURCHASE', 'ONLINE_PAYMENT', 'P2P_TRANSFER', 'ATM_WITHDRAWAL'])[1 + (gs % 4)],
    (gs % 25 = 0)
FROM generate_series(1, 15000) AS gs;

-- Инъекция фрод-кейса №1: Impossible Travel (Москва -> Владивосток за 18 минут)
INSERT INTO bank.transactions (account_id, tx_timestamp, amount, merchant_category, tx_city, tx_type, is_declined) VALUES
(10, '2026-10-15 14:10:00', 4500.00, 'Restaurants', 'Moscow', 'POS_PURCHASE', FALSE),
(10, '2026-10-15 14:28:00', 89000.00, 'Electronics', 'Vladivostok', 'POS_PURCHASE', FALSE);

-- Инъекция фрод-кейса №2: Card Testing (3 мелких списания по 10-50 руб. и затем крупное на 145 000 руб.)
INSERT INTO bank.transactions (account_id, tx_timestamp, amount, merchant_category, tx_city, tx_type, is_declined) VALUES
(25, '2026-10-20 03:11:00', 15.00, 'Digital_Services', 'Moscow', 'ONLINE_PAYMENT', TRUE),
(25, '2026-10-20 03:12:10', 25.00, 'Digital_Services', 'Moscow', 'ONLINE_PAYMENT', FALSE),
(25, '2026-10-20 03:13:05', 50.00, 'Digital_Services', 'Moscow', 'ONLINE_PAYMENT', FALSE),
(25, '2026-10-20 03:14:40', 145000.00, 'Electronics', 'Moscow', 'ONLINE_PAYMENT', FALSE);

-- Инъекция фрод-кейса №3: Цепочка транзитного отмывания средств (P2P-цепочка из 5 звеньев)
INSERT INTO bank.p2p_transfers (from_account_id, to_account_id, transfer_time, amount) VALUES
(101, 102, '2026-10-22 10:00:00', 500000.00),
(102, 103, '2026-10-22 10:07:00', 495000.00),
(103, 104, '2026-10-22 10:15:00', 490000.00),
(104, 105, '2026-10-22 10:22:00', 485000.00),
(105, 106, '2026-10-22 10:30:00', 480000.00);
