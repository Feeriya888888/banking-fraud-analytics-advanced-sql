-- ============================================================================
-- 02_fraud_detection.sql
-- Продвинутые SQL-запросы для антифрод-мониторинга и выявления аномалий
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ЗАПРОС 1: Выявление паттерна "Impossible Travel" (невозможная скорость перемещения)
-- Логика: физическая операция (POS/ATM) в другом городе менее чем через 2 часа
-- после предыдущей физической операции по той же карте.
-- ----------------------------------------------------------------------------
WITH physical_tx AS (
    SELECT 
        t.tx_id,
        t.account_id,
        c.full_name,
        t.tx_timestamp,
        t.tx_city AS current_city,
        t.amount,
        LAG(t.tx_city) OVER (PARTITION BY t.account_id ORDER BY t.tx_timestamp) AS prev_city,
        LAG(t.tx_timestamp) OVER (PARTITION BY t.account_id ORDER BY t.tx_timestamp) AS prev_timestamp
    FROM bank.transactions t
    JOIN bank.accounts a ON t.account_id = a.account_id
    JOIN bank.customers c ON a.customer_id = c.customer_id
    WHERE t.tx_type IN ('POS_PURCHASE', 'ATM_WITHDRAWAL')
      AND t.is_declined = FALSE
)
SELECT 
    tx_id,
    account_id,
    full_name,
    prev_city || ' -> ' || current_city AS route,
    prev_timestamp,
    tx_timestamp,
    ROUND(EXTRACT(EPOCH FROM (tx_timestamp - prev_timestamp)) / 60.0, 1) AS minutes_between_tx,
    amount AS suspicious_amount
FROM physical_tx
WHERE prev_city IS NOT NULL
  AND prev_city <> current_city
  AND (tx_timestamp - prev_timestamp) < INTERVAL '2 hours'
ORDER BY minutes_between_tx ASC;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 2: Детекция "Card Testing" (проверка карты микротранзакциями)
-- Логика: использование оконных фреймов (RANGE BETWEEN) для поиска счетов,
-- где в течение 15 минут прошли >= 2 мелкие операции (< 100 руб.), а сразу за ними
-- последовала крупная покупка (> 50 000 руб.).
-- ----------------------------------------------------------------------------
WITH velocity_metrics AS (
    SELECT 
        tx_id,
        account_id,
        tx_timestamp,
        amount,
        is_declined,
        COUNT(*) FILTER (WHERE amount < 100) OVER (
            PARTITION BY account_id 
            ORDER BY tx_timestamp 
            RANGE BETWEEN INTERVAL '15 minutes' PRECEDING AND INTERVAL '1 second' PRECEDING
        ) AS micro_tx_count_15m,
        COUNT(*) FILTER (WHERE is_declined = TRUE) OVER (
            PARTITION BY account_id 
            ORDER BY tx_timestamp 
            RANGE BETWEEN INTERVAL '15 minutes' PRECEDING AND INTERVAL '1 second' PRECEDING
        ) AS declined_count_15m
    FROM bank.transactions
)
SELECT 
    v.tx_id,
    v.account_id,
    c.full_name,
    v.tx_timestamp,
    v.amount AS main_fraud_amount,
    v.micro_tx_count_15m,
    v.declined_count_15m
FROM velocity_metrics v
JOIN bank.accounts a ON v.account_id = a.account_id
JOIN bank.customers c ON a.customer_id = c.customer_id
WHERE v.amount >= 50000
  AND v.micro_tx_count_15m >= 2
ORDER BY v.tx_timestamp DESC;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 3: Поиск транзитных цепочек отмывания средств (WITH RECURSIVE)
-- Логика: рекурсивный обход графа P2P-переводов для поиска цепочек длиной >= 3,
-- где каждый следующий перевод совершается в течение 30 минут с сохранением > 90% суммы.
-- ----------------------------------------------------------------------------
WITH RECURSIVE transfer_chains AS (
    -- Базовый шаг: начальный перевод
    SELECT 
        transfer_id,
        from_account_id AS origin_account,
        from_account_id,
        to_account_id,
        transfer_time,
        amount,
        1 AS hop_count,
        ARRAY[from_account_id, to_account_id] AS account_path
    FROM bank.p2p_transfers
    WHERE amount >= 100000

    UNION ALL

    -- Рекурсивный шаг: присоединение следующего звена цепочки
    SELECT 
        p.transfer_id,
        tc.origin_account,
        p.from_account_id,
        p.to_account_id,
        p.transfer_time,
        p.amount,
        tc.hop_count + 1,
        tc.account_path || p.to_account_id
    FROM bank.p2p_transfers p
    INNER JOIN transfer_chains tc ON p.from_account_id = tc.to_account_id
    WHERE p.transfer_time > tc.transfer_time
      AND p.transfer_time <= tc.transfer_time + INTERVAL '30 minutes'
      AND p.amount >= tc.amount * 0.90
      AND NOT (p.to_account_id = ANY(tc.account_path)) -- Защита от зацикливания
)
SELECT 
    origin_account,
    to_account_id AS final_beneficiary_account,
    hop_count AS chain_length,
    amount AS final_amount,
    array_to_string(account_path, ' -> ') AS money_flow_path
FROM transfer_chains
WHERE hop_count >= 3
ORDER BY hop_count DESC, final_amount DESC;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 4: Статистические выбросы по Z-Score (отклонение от профиля клиента)
-- Логика: поиск покупок, превышающих среднюю трату клиента более чем на 4 сигмы.
-- ----------------------------------------------------------------------------
WITH client_stats AS (
    SELECT 
        tx_id,
        account_id,
        tx_timestamp,
        merchant_category,
        amount,
        AVG(amount) OVER (PARTITION BY account_id) AS avg_client_amount,
        STDDEV_SAMP(amount) OVER (PARTITION BY account_id) AS stddev_client_amount,
        COUNT(*) OVER (PARTITION BY account_id) AS total_tx
    FROM bank.transactions
    WHERE is_declined = FALSE
)
SELECT 
    tx_id,
    account_id,
    tx_timestamp,
    merchant_category,
    amount,
    ROUND(avg_client_amount, 2) AS client_avg,
    ROUND((amount - avg_client_amount) / NULLIF(stddev_client_amount, 0), 2) AS z_score
FROM client_stats
WHERE total_tx >= 10
  AND stddev_client_amount > 0
  AND (amount - avg_client_amount) / stddev_client_amount > 4.0
ORDER BY z_score DESC;
