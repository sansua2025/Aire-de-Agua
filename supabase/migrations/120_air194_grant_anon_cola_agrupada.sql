-- 120_air194_grant_anon_cola_agrupada.sql
-- AIR-194 — view_dashboard_cola_agrupada era la ÚNICA view_dashboard_* sin SELECT
-- para anon (tenía authenticated=r por error histórico; el dashboard usa anon — mig 037).
-- El widget de cola AI del Overview fallaba 42501 EN SILENCIO (catch silencioso);
-- AIR-194 honesta los errores y el 42501 tumbaba el Overview completo.
-- Alinea el grant con las otras 15 vistas del dashboard.
GRANT SELECT ON analytics.view_dashboard_cola_agrupada TO anon;
