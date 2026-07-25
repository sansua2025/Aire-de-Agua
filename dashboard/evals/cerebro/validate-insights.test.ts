import { describe, it, expect } from "vitest";
import { validateInsights, type Hecho, type InsightIn } from "./validate-insights";

/**
 * validate-insights.test.ts — AIR-239 (Loop v3 F1-b) · CA3.
 *
 * Test determinista (sin BD) de la lógica del validador post-parse que corre en
 * el nodo n8n "Parse Claude + split insights" del workflow E5A. La función pura
 * vive en ./validate-insights.ts (fuente canónica); el jsCode del nodo lleva un
 * ESPEJO byte-equivalente. Este test ejercita la lógica compartida:
 *   (a) insight_key inventado (no respaldado por ningún hecho) → DESCARTADO.
 *   (b) hipotesis_foo con score 0.4 → ACEPTADO como fuente=hipotesis.
 *   (c) key de un hecho pero con un número que difiere → DESCARTADO.
 * Más los bordes: match exacto aceptado, muestra insuficiente descartada,
 * hipótesis con score alto descartada, y tope de 1 hipótesis.
 */

const hechoDisparado: Hecho = {
  insight_key: "klaviyo_canal_apagado",
  disparado: true,
  muestra_suficiente: true,
  valor_observado: 0,
  valor_referencia: 12000,
  metrica_clave: "emails_enviados",
};

const hechoMuestraInsuf: Hecho = {
  insight_key: "mix_canal_dominante",
  disparado: true,
  muestra_suficiente: false, // señal débil (n bajo) → nunca genera insight
  valor_observado: 0.73,
  valor_referencia: 0.5,
  metrica_clave: "share_revenue_canal",
};

describe("validateInsights (AIR-239 F1-b)", () => {
  it("(a) descarta un insight_key inventado, no respaldado por hecho", () => {
    const insights: InsightIn[] = [
      { insight_key: "key_inventado_xyz", valor_observado: 42, metrica_clave: "x" },
    ];
    const r = validateInsights(insights, [hechoDisparado]);
    expect(r.accepted).toHaveLength(0);
    expect(r.discarded).toEqual([
      { insight_key: "key_inventado_xyz", motivo: "key_no_respaldado_por_hecho" },
    ]);
  });

  it("(b) acepta hipotesis_foo con score 0.4 y la etiqueta fuente=hipotesis", () => {
    const insights: InsightIn[] = [
      { insight_key: "hipotesis_foo", score_confianza: 0.4, valor_observado: null },
    ];
    const r = validateInsights(insights, [hechoDisparado]);
    expect(r.discarded).toHaveLength(0);
    expect(r.accepted).toHaveLength(1);
    expect(r.accepted[0].fuente).toBe("hipotesis");
    expect(r.accepted[0].insight_key).toBe("hipotesis_foo");
  });

  it("(c) descarta un insight con key de hecho pero número que difiere", () => {
    const insights: InsightIn[] = [
      {
        insight_key: "klaviyo_canal_apagado",
        valor_observado: 999, // difiere del hecho (0)
        valor_referencia: 12000,
        metrica_clave: "emails_enviados",
      },
    ];
    const r = validateInsights(insights, [hechoDisparado]);
    expect(r.accepted).toHaveLength(0);
    expect(r.discarded[0]).toEqual({
      insight_key: "klaviyo_canal_apagado",
      motivo: "numeros_no_coinciden_con_hecho",
    });
  });

  it("acepta un insight que copia el hecho 1:1 y lo etiqueta fuente=detector", () => {
    const insights: InsightIn[] = [
      {
        insight_key: "klaviyo_canal_apagado",
        valor_observado: 0,
        valor_referencia: 12000,
        metrica_clave: "emails_enviados",
      },
    ];
    const r = validateInsights(insights, [hechoDisparado]);
    expect(r.discarded).toHaveLength(0);
    expect(r.accepted).toHaveLength(1);
    expect(r.accepted[0].fuente).toBe("detector");
  });

  it("descarta un insight sobre un hecho con muestra insuficiente (señal débil)", () => {
    const insights: InsightIn[] = [
      {
        insight_key: "mix_canal_dominante",
        valor_observado: 0.73,
        valor_referencia: 0.5,
        metrica_clave: "share_revenue_canal",
      },
    ];
    const r = validateInsights(insights, [hechoMuestraInsuf]);
    expect(r.accepted).toHaveLength(0);
    expect(r.discarded[0].motivo).toBe("hecho_no_disparado_o_muestra_insuficiente");
  });

  it("descarta hipótesis con score > 0.5 y respeta el tope de 1 hipótesis", () => {
    const insights: InsightIn[] = [
      { insight_key: "hipotesis_alta", score_confianza: 0.6 },
      { insight_key: "hipotesis_uno", score_confianza: 0.3 },
      { insight_key: "hipotesis_dos", score_confianza: 0.3 },
    ];
    const r = validateInsights(insights, []);
    // hipotesis_alta descartada (score alto); hipotesis_uno aceptada; hipotesis_dos por tope.
    expect(r.accepted.map((a) => a.insight_key)).toEqual(["hipotesis_uno"]);
    const motivos = r.discarded.reduce<Record<string, string>>((acc, d) => {
      if (d.insight_key) acc[d.insight_key] = d.motivo;
      return acc;
    }, {});
    expect(motivos["hipotesis_alta"]).toBe("hipotesis_score_invalido");
    expect(motivos["hipotesis_dos"]).toBe("hipotesis_excede_max_1");
  });

  it("descarta un insight sin insight_key", () => {
    const insights: InsightIn[] = [{ valor_observado: 1 } as InsightIn];
    const r = validateInsights(insights, [hechoDisparado]);
    expect(r.accepted).toHaveLength(0);
    expect(r.discarded[0]).toEqual({ insight_key: null, motivo: "sin_insight_key" });
  });
});
