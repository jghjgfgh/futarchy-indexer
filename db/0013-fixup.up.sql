-- NOTE: already made on staging
CREATE INDEX ON prices (market_acct, created_at);

ALTER TABLE prices_chart_data RENAME TO prices_chart_data_old_2025_01_19;

CREATE TABLE prices_chart_data
(
  interv TIMESTAMPTZ NOT NULL,
  price NUMERIC NOT NULL,
  base_amount  NUMERIC,
  quote_amount NUMERIC,
  prices_type TEXT NOT NULL,
  market_acct TEXT NOT NULL,
  bar_size INTERVAL NOT NULL,
  PRIMARY KEY (market_acct, prices_type, bar_size, interv)
);

-- NOTE: check stats after running for a bit and remove unused
CREATE INDEX ON prices_chart_data (bar_size, market_acct, prices_type, interv DESC NULLS LAST);
CREATE INDEX ON prices_chart_data (market_acct, interv);
CREATE INDEX ON prices_chart_data (market_acct, prices_type, bar_size);

CREATE or replace FUNCTION generate_rollup_prices(_bar_size INTERVAL)
RETURNS VOID
LANGUAGE SQL
AS
$$
  WITH base AS
  (
    select market_acct,
           prices_type,
           min(interv) AS base_min_interv,
           max(interv) AS base_max_interv
    from prices_chart_data_v3
    where bar_size = '30 seconds'
    group by market_acct, prices_type
  ),
  current_bar as
  (
    select market_acct,
           prices_type,
           min(interv) AS current_min_interv,
           max(interv) AS current_max_interv
    FROM prices_chart_data_v3
    where bar_size = _bar_size
    group by market_acct, prices_type
  ),
  to_generate as materialized
  (
    SELECT market_acct,
           prices_type,
           generate_series(COALESCE(current_max_interv + _bar_size, time_bucket(_bar_size, base_min_interv)),
                           time_bucket(_bar_size, base_max_interv) - _bar_size,
                           _bar_size) AS ts
    FROM base natural left join current_bar
  )
  insert into prices_chart_data_v3 (interv, price, base_amount, quote_amount, prices_type, market_acct, bar_size)
  select to_generate.ts, pcd.price, pcd.base_amount, pcd.quote_amount, pcd.prices_type, pcd.market_acct, _bar_size
  from to_generate
  join prices_chart_data_v3 as pcd
  on pcd.bar_size = '30 seconds'
  and to_generate.ts + _bar_size = pcd.interv
  and to_generate.market_acct = pcd.market_acct
  and to_generate.prices_type = pcd.prices_type;
$$;

CREATE FUNCTION generate_forward_filled_prices()
RETURNS VOID
LANGUAGE PLPGSQL
AS
$$
DECLARE
  market_record RECORD;
BEGIN
    -- -- Get the latest timestamp minus an hour
    -- SELECT MAX(interv) - INTERVAL '1 hour'
    -- INTO last_update
    -- FROM prices_chart_data;

    -- Loop through each market from the aggregate markets CTE
     FOR market_record IN (
        WITH proposal_pass_markets AS (
            SELECT
                CASE
                    WHEN pass_market_acct IS NOT NULL THEN pass_market_acct
                    ELSE NULL
                END AS market_acct,
                created_at,
                COALESCE(ended_at, completed_at, NOW()) AS ended_at,
                'conditional' AS prices_type
            FROM proposals
        ),
      proposal_fail_markets AS (
          SELECT
              CASE
                  WHEN fail_market_acct IS NOT NULL THEN fail_market_acct
                  ELSE NULL
              END AS market_acct,
              created_at,
              COALESCE(ended_at, completed_at, NOW()) AS ended_at,
              'conditional' AS prices_type
          FROM proposals
      ),
      metric_markets AS (
          SELECT
              amm_addr AS market_acct,
              created_at,
              COALESCE(completed_at, NOW()) AS ended_at,
              'conditional' AS prices_type
          FROM v0_4_metric_decisions
          WHERE amm_addr IS NOT NULL
      ),
      distinct_markets AS (
          SELECT * FROM proposal_pass_markets
          UNION ALL
          SELECT * FROM proposal_fail_markets
          UNION ALL
          SELECT * FROM metric_markets
      ),
      spot_markets AS (
          SELECT DISTINCT ON (market_acct)
              market_acct,
              daos.created_at AS created_at,
              NOW() AS ended_at,
              'spot' AS prices_type
          FROM markets
          LEFT JOIN daos ON daos.base_acct = markets.market_acct
          WHERE market_acct NOT IN(SELECT market_acct FROM distinct_markets)
              AND proposal_acct IS NULL
              AND daos.base_acct IS NOT NULL
          ORDER BY market_acct, created_at
      ),
      all_markets AS
      (
        SELECT * FROM spot_markets
        UNION ALL
        SELECT * FROM distinct_markets
      ),
      pre_final AS
      (
        SELECT market_acct,
               prices_type,
               created_at,
               ended_at,
               last_update,
               COALESCE(last_update + INTERVAL '30 seconds', TIME_BUCKET(INTERVAL '30 seconds', created_at)) AS start_ts,
               TIME_BUCKET(INTERVAL '30 seconds', LEAST(NOW() - INTERVAL '30 seconds', ended_at)) AS end_ts
        FROM all_markets
        NATURAL LEFT JOIN
        (
          SELECT market_acct,
                 prices_type,
                 MAX(interv) AS last_update
          FROM prices_chart_data
          WHERE bar_size = INTERVAL '30 seconds'
          GROUP BY market_acct, prices_type
        ) AS tt
      )
      SELECT *
      FROM pre_final
      WHERE start_ts <= end_ts
      -- skip markets without prices
      AND ((last_update IS NOT NULL)
           OR
           EXISTS (select 1
                   from prices
                   where prices.market_acct = pre_final.market_acct
                   and prices.created_at >= pre_final.start_ts
                   and prices.created_at <= pre_final.end_ts + INTERVAL '30 seconds'
                   limit 1))
    ) LOOP
        -- -- empty range
        -- CONTINUE WHEN market_record.start_ts >= market_record.end_ts;

        -- RAISE NOTICE 'RECORD A: %', market_record;

        -- -- optimization for markets that don't have any prices yet
        -- CONTINUE WHEN market_record.last_update IS NULL AND NOT EXISTS (select 1
        --                                                                 from prices
        --                                                                 where market_acct = market_record.market_acct
        --                                                                 and created_at >= market_record.start_ts
        --                                                                 and created_at <= market_record.end_ts + INTERVAL '30 seconds'
        --                                                                 limit 1);

        -- RAISE NOTICE 'RECORD: %', market_record;

        -- Insert forward filled data for this market
        INSERT INTO prices_chart_data (
            interv, price, base_amount, quote_amount, prices_type, market_acct, bar_size
        )
        WITH series AS (
            SELECT generate_series(
                market_record.start_ts,
                market_record.end_ts,
                INTERVAL '30 seconds'
            ) AS time_series_generated
        ), matching_amm_data AS (
            SELECT
                TIME_BUCKET(INTERVAL '30 seconds', prices.created_at) AS interv,
                LAST(prices.price, prices.created_at) AS price,
                LAST(prices.base_amount, prices.created_at) AS base_amount,
                LAST(prices.quote_amount, prices.created_at) AS quote_amount,
                LAST(prices_type, prices.created_at) AS prices_type,
                LAST(markets.market_acct, prices.created_at) AS market_acct
            -- TODO: fix the join...
            FROM prices
            JOIN markets ON markets.market_acct::text = prices.market_acct::text
                AND markets.market_acct = market_record.market_acct
            WHERE prices.created_at >= market_record.start_ts
                AND prices.created_at <= market_record.end_ts + INTERVAL '30 seconds'
            GROUP BY TIME_BUCKET(INTERVAL '30 seconds', prices.created_at), prices_type, markets.market_acct
        ),
        including_prev AS
        (
          SELECT interv, price, base_amount, quote_amount, prices_type, market_acct FROM matching_amm_data
          UNION ALL
          (
            SELECT interv, price, base_amount, quote_amount, prices_type, market_acct FROM prices_chart_data
            WHERE market_acct = market_record.market_acct
            AND prices_type = market_record.prices_type
            AND interv < market_record.start_ts
            AND bar_size = INTERVAL '30 seconds'
            ORDER BY interv DESC NULLS LAST
            LIMIT 1
          )
        ),
        including_next AS
        (
          SELECT * FROM including_prev
          UNION ALL
          SELECT market_record.end_ts + interval '30 seconds' AS interv,
                 NULL AS price,
                 NULL AS base_amount,
                 NULL AS quote_amount,
                 market_record.prices_type AS prices_type,
                 market_record.market_acct AS market_acct
          WHERE market_record.end_ts NOT IN (SELECT interv FROM matching_amm_data)
        ),
        with_lags AS
        (
          SELECT market_acct,
                 prices_type,
                 interv,
                 lag(interv, 1) over (partition by market_acct order by interv) as interv_lag,
                 lag(price, 1) over (partition by market_acct order by interv) as price_lag,
                 lag(base_amount, 1) over (partition by market_acct order by interv) AS base_amount_lag,
                 lag(quote_amount, 1) over (partition by market_acct order by interv) AS quote_amount_lag
          FROM including_next
        ),
        ffill_bars AS
        (
          SELECT generate_series(interv_lag + interval '30 seconds', interv - interval '30 seconds', interval '30 seconds') AS interv,
                 price_lag AS price,
                 base_amount_lag AS base_amount,
                 quote_amount_lag AS quote_amount,
                 prices_type,
                 market_acct
          from with_lags
          where interv - interv_lag > interval '30 seconds'
        ),
        final_union AS
        (
          SELECT * FROM matching_amm_data
          UNION ALL
          SELECT * FROM ffill_bars
        )
        SELECT *, INTERVAL '30 seconds' AS bar_size FROM final_union
        ON CONFLICT (market_acct, prices_type, interv, bar_size) DO NOTHING;
    END LOOP;
END;
$$;


-- CREATE FUNCTION test_generate_rollup_bars()
-- RETURNS VOID
-- LANGUAGE PLPGSQL
-- AS
-- $$

-- $$;


-- check for gaps
-- with base as
-- (
--   select market_acct,
--          interv,
--          lag(interv, 1) over (partition by market_acct order by interv) as interv_lag
--   from prices_chart_data
--   WHERE bar_size = INTERVAL '30 seconds'
-- )
-- select *
-- from base
-- where interv - interv_lag > interval '30 seconds';




CREATE TABLE twaps_chart_data
(
  interv TIMESTAMPTZ NOT NULL,
  token_amount NUMERIC NOT NULL,
  market_acct TEXT NOT NULL,
  bar_size INTERVAL NOT NULL,
  PRIMARY KEY (market_acct, interv, bar_size)
);


CREATE FUNCTION generate_forward_filled_twaps()
RETURNS VOID
LANGUAGE PLPGSQL
AS
$$
DECLARE
  market_record RECORD;
BEGIN
    FOR market_record IN (
        WITH proposal_pass_markets AS (
            SELECT
                CASE
                    WHEN pass_market_acct IS NOT NULL THEN pass_market_acct
                    ELSE NULL
                END AS market_acct,
                created_at,
                COALESCE(ended_at, completed_at, NOW()) AS ended_at
            FROM proposals
        ),
        proposal_fail_markets AS (
            SELECT
                CASE
                    WHEN fail_market_acct IS NOT NULL THEN fail_market_acct
                    ELSE NULL
                END AS market_acct,
                created_at,
                COALESCE(ended_at, completed_at, NOW()) AS ended_at
            FROM proposals
        ),
        metric_markets AS (
            SELECT
                amm_addr AS market_acct,
                created_at,
                COALESCE(completed_at, NOW()) AS ended_at
            FROM v0_4_metric_decisions
            WHERE amm_addr IS NOT NULL
        ),
        distinct_markets AS (
            SELECT * FROM proposal_pass_markets
            UNION ALL
            SELECT * FROM proposal_fail_markets
            UNION ALL
            SELECT * FROM metric_markets
        ),
        spot_markets AS (
            SELECT DISTINCT ON (market_acct)
                market_acct,
                daos.created_at AS created_at,
                NOW() AS ended_at
            FROM markets
            LEFT JOIN daos ON daos.base_acct = markets.market_acct
            WHERE market_acct NOT IN (SELECT market_acct FROM distinct_markets)
              AND proposal_acct IS NULL
              AND daos.base_acct IS NOT NULL
            ORDER BY market_acct, created_at
        ),
        all_markets AS (
            SELECT * FROM spot_markets
            UNION ALL
            SELECT * FROM distinct_markets
        ),
        pre_final AS (
            SELECT market_acct,
                   created_at,
                   ended_at,
                   last_update,
                   COALESCE(last_update + INTERVAL '30 seconds', TIME_BUCKET(INTERVAL '30 seconds', created_at)) AS start_ts,
                   TIME_BUCKET(INTERVAL '30 seconds', LEAST(NOW() - INTERVAL '30 seconds', ended_at)) AS end_ts
            FROM all_markets
            NATURAL LEFT JOIN
            (
              SELECT market_acct,
                     MAX(interv) AS last_update
              FROM twaps_chart_data
              WHERE bar_size = INTERVAL '30 seconds'
              GROUP BY market_acct
            ) AS tt
        )
        SELECT *
        FROM pre_final
        WHERE start_ts <= end_ts
          AND (
              last_update IS NOT NULL
              OR EXISTS (
                   SELECT 1
                   FROM twaps
                   WHERE twaps.market_acct = pre_final.market_acct
                     AND twaps.created_at >= pre_final.start_ts
                     AND twaps.created_at <= pre_final.end_ts + INTERVAL '30 seconds'
                   LIMIT 1
              )
          )
    ) LOOP
        INSERT INTO twaps_chart_data (
            interv, token_amount, market_acct, bar_size
        )
        WITH series AS (
            SELECT generate_series(
                market_record.start_ts,
                market_record.end_ts,
                INTERVAL '30 seconds'
            ) AS time_series_generated
        ),
        matching_twaps_data AS (
            SELECT
                TIME_BUCKET(INTERVAL '30 seconds', twaps.created_at) AS interv,
                LAST(twaps.token_amount, twaps.created_at) AS token_amount,
                twaps.market_acct
            FROM twaps
            JOIN markets ON markets.market_acct::text = twaps.market_acct::text
              AND markets.market_acct = market_record.market_acct
            WHERE twaps.created_at >= market_record.start_ts
              AND twaps.created_at <= market_record.end_ts + INTERVAL '30 seconds'
            GROUP BY TIME_BUCKET(INTERVAL '30 seconds', twaps.created_at), twaps.market_acct
        ),
        including_prev AS (
            SELECT interv, token_amount, market_acct FROM matching_twaps_data
            UNION ALL
            (
              SELECT interv, token_amount, market_acct
              FROM twaps_chart_data
              WHERE market_acct = market_record.market_acct
                AND interv < market_record.start_ts
                AND bar_size = INTERVAL '30 seconds'
              ORDER BY interv DESC NULLS LAST
              LIMIT 1
            )
        ),
        including_next AS (
            SELECT * FROM including_prev
            UNION ALL
            SELECT market_record.end_ts + INTERVAL '30 seconds' AS interv,
                   NULL::NUMERIC AS token_amount,
                   market_record.market_acct AS market_acct
            WHERE market_record.end_ts NOT IN (SELECT interv FROM matching_twaps_data)
        ),
        with_lags AS (
            SELECT market_acct,
                   interv,
                   lag(interv, 1) OVER (PARTITION BY market_acct ORDER BY interv) AS interv_lag,
                   lag(token_amount, 1) OVER (PARTITION BY market_acct ORDER BY interv) AS token_amount_lag
            FROM including_next
        ),
        ffill_bars AS (
            SELECT generate_series(interv_lag + INTERVAL '30 seconds', interv - INTERVAL '30 seconds', INTERVAL '30 seconds') AS interv,
                   token_amount_lag AS token_amount,
                   market_acct
            FROM with_lags
            WHERE interv - interv_lag > INTERVAL '30 seconds'
        ),
        final_union AS (
            SELECT * FROM matching_twaps_data
            UNION ALL
            SELECT * FROM ffill_bars
        )
        SELECT *, INTERVAL '30 seconds' AS bar_size FROM final_union
        ON CONFLICT (market_acct, interv, bar_size) DO NOTHING;
    END LOOP;
END;
$$;
