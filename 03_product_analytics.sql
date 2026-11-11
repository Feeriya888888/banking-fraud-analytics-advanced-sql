-- ============================================================================
-- 03_product_analytics.sql
-- Продуктовая и финансовая аналитика: когорты, LTV, MoM-рост, ABC-сегментация
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ЗАПРОС 1: Когортный анализ удержания клиентов (Cohort Retention Matrix)
-- Логика: группировка клиентов по месяцу первой успешной транзакции и расчёт
-- процента активных пользователей в каждый последующий месяц жизни (Month 0..N).
-- ----------------------------------------------------------------------------
WITH user_first_tx AS (
    SELECT 
        a.customer_id,
        DATE_TRUNC('month', MIN(t.tx_timestamp))::DATE AS cohort_month
    FROM bank.transactions t
    JOIN bank.accounts a ON t.account_id = a.account_id
    WHERE t.is_declined = FALSE
    GROUP BY a.customer_id
),
user_monthly_activity AS (
    SELECT DISTINCT
        a.customer_id,
        f.cohort_month,
        (EXTRACT(YEAR FROM t.tx_timestamp) - EXTRACT(YEAR FROM f.cohort_month)) * 12 +
        (EXTRACT(MONTH FROM t.tx_timestamp) - EXTRACT(MONTH FROM f.cohort_month)) AS month_number
    FROM bank.transactions t
    JOIN bank.accounts a ON t.account_id = a.account_id
    JOIN user_first_tx f ON a.customer_id = f.customer_id
    WHERE t.is_declined = FALSE
),
cohort_sizes AS (
    SELECT cohort_month, COUNT(DISTINCT customer_id) AS initial_users
    FROM user_first_tx
    GROUP BY cohort_month
)
SELECT 
    a.cohort_month,
    s.initial_users,
    a.month_number,
    COUNT(DISTINCT a.customer_id) AS active_users,
    ROUND((COUNT(DISTINCT a.customer_id)::NUMERIC / s.initial_users) * 100, 2) AS retention_rate_pct
FROM user_monthly_activity a
JOIN cohort_sizes s ON a.cohort_month = s.cohort_month
WHERE a.month_number BETWEEN 0 AND 6
GROUP BY a.cohort_month, s.initial_users, a.month_number
ORDER BY a.cohort_month, a.month_number;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 2: Непрерывный дневной отчёт с заполнением пропусков (RECURSIVE CTE)
-- и расчётом 7-дневной скользящей средней + нарастающего итога (Running Total)
-- ----------------------------------------------------------------------------
WITH RECURSIVE calendar AS (
    SELECT DATE '2026-10-01' AS report_date
    UNION ALL
    SELECT (report_date + INTERVAL '1 day')::DATE
    FROM calendar
    WHERE report_date < DATE '2026-10-31'
),
daily_turnover AS (
    SELECT 
        tx_timestamp::DATE AS tx_date,
        SUM(amount) AS daily_volume,
        COUNT(*) AS tx_count
    FROM bank.transactions
    WHERE is_declined = FALSE
      AND tx_timestamp >= '2026-10-01' AND tx_timestamp < '2026-11-01'
    GROUP BY tx_timestamp::DATE
)
SELECT 
    c.report_date,
    COALESCE(d.tx_count, 0) AS tx_count,
    COALESCE(d.daily_volume, 0.00) AS daily_volume,
    -- Нарастающий итог с начала месяца
    SUM(COALESCE(d.daily_volume, 0)) OVER (ORDER BY c.report_date) AS mtd_running_total,
    -- Скользящее среднее за 7 дней
    ROUND(AVG(COALESCE(d.daily_volume, 0)) OVER (
        ORDER BY c.report_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 2) AS moving_avg_7d
FROM calendar c
LEFT JOIN daily_turnover d ON c.report_date = d.tx_date
ORDER BY c.report_date;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 3: ABC-сегментация клиентов по объёму транзакций (Принцип Парето)
-- Логика: распределение клиентов на группы A (80% выручки), B (15%) и C (5%)
-- с использованием кумулятивной суммы и процентного вклада.
-- ----------------------------------------------------------------------------
WITH customer_volumes AS (
    SELECT 
        c.customer_id,
        c.full_name,
        c.segment,
        SUM(t.amount) AS total_spent,
        COUNT(t.tx_id) AS total_transactions
    FROM bank.customers c
    JOIN bank.accounts a ON c.customer_id = a.customer_id
    JOIN bank.transactions t ON a.account_id = t.account_id
    WHERE t.is_declined = FALSE
    GROUP BY c.customer_id, c.full_name, c.segment
),
cumulative_shares AS (
    SELECT 
        *,
        SUM(total_spent) OVER (ORDER BY total_spent DESC) / SUM(total_spent) OVER () AS cumulative_revenue_share
    FROM customer_volumes
)
SELECT 
    customer_id,
    full_name,
    segment AS crm_segment,
    total_transactions,
    total_spent,
    ROUND(cumulative_revenue_share * 100, 2) AS cumulative_share_pct,
    CASE 
        WHEN cumulative_revenue_share <= 0.80 THEN 'A (Top 80% Volume)'
        WHEN cumulative_revenue_share <= 0.95 THEN 'B (Next 15% Volume)'
        ELSE 'C (Bottom 5% Volume)'
    END AS abc_class
FROM cumulative_shares
ORDER BY total_spent DESC
LIMIT 50;


-- ----------------------------------------------------------------------------
-- ЗАПРОС 4: Помесячная динамика категорий (MoM Growth % и доля в обороте)
-- ----------------------------------------------------------------------------
WITH monthly_cat AS (
    SELECT 
        DATE_TRUNC('month', tx_timestamp)::DATE AS report_month,
        merchant_category,
        SUM(amount) AS category_volume
    FROM bank.transactions
    WHERE is_declined = FALSE
    GROUP BY DATE_TRUNC('month', tx_timestamp)::DATE, merchant_category
)
SELECT 
    report_month,
    merchant_category,
    category_volume,
    ROUND((category_volume / SUM(category_volume) OVER (PARTITION BY report_month)) * 100, 2) AS share_of_month_pct,
    LAG(category_volume) OVER (PARTITION BY merchant_category ORDER BY report_month) AS prev_month_volume,
    ROUND(
        ((category_volume - LAG(category_volume) OVER (PARTITION BY merchant_category ORDER BY report_month)) / 
        NULLIF(LAG(category_volume) OVER (PARTITION BY merchant_category ORDER BY report_month), 0)) * 100, 
    2) AS mom_growth_pct
FROM monthly_cat
ORDER BY report_month DESC, category_volume DESC;
