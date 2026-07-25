// AIR-239 · Loop v3 F1-b — Validador post-parse "el LLM narra sobre hechos".
//
// FUENTE CANÓNICA de la lógica del validador. Este módulo es la referencia
// importable por el test (detectors-eval / validate-insights.test.ts). El nodo
// n8n "Parse Claude + split insights" (E5A_Loop_Weekly_Analysis.json) lleva un
// ESPEJO byte-equivalente de `validateInsights` en su jsCode (los code nodes de
// n8n no pueden `import`). Si cambias la lógica aquí, replica el mismo cambio en
// el jsCode del nodo y viceversa.
//
// Contrato: cada `hecho` proviene de analytics.evaluate_detectors (mig 134),
// normalizado en "Build Prompt (sanitized)" a { insight_key, disparado,
// muestra_suficiente, valor_observado, valor_referencia, metrica_clave, ... }.
// Un insight del LLM es ACEPTADO solo si:
//   (a) su insight_key coincide con un hecho disparado=true Y muestra_suficiente=true,
//       y valor_observado/valor_referencia/metrica_clave son IGUALES al hecho; o
//   (b) su insight_key empieza por "hipotesis_" con score_confianza<=0.5 (máx. 1).
// Todo lo demás se DESCARTA con motivo (para log/auditoría).

export interface Hecho {
  insight_key: string;
  disparado?: boolean;
  muestra_suficiente?: boolean;
  valor_observado?: number | null;
  valor_referencia?: number | null;
  metrica_clave?: string | null;
  [k: string]: unknown;
}

export interface InsightIn {
  insight_key?: unknown;
  valor_observado?: number | null;
  valor_referencia?: number | null;
  metrica_clave?: string | null;
  score_confianza?: number | null;
  [k: string]: unknown;
}

export type Fuente = "detector" | "hipotesis";

export interface Accepted {
  insight: InsightIn & { fuente: Fuente };
  fuente: Fuente;
}

export interface Discarded {
  insight_key: string | null;
  motivo: string;
}

export interface ValidationResult {
  accepted: Array<InsightIn & { fuente: Fuente }>;
  discarded: Discarded[];
}

// Igualdad numérica null-safe: null==null → true; distinto tipo/valor → false.
function numEq(a: unknown, b: unknown): boolean {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return Number(a) === Number(b);
}

export function validateInsights(
  insights: InsightIn[] | null | undefined,
  hechos: Hecho[] | null | undefined,
): ValidationResult {
  const byKey: Record<string, Hecho> = {};
  for (const h of hechos || []) {
    if (h && typeof h.insight_key === "string") byKey[h.insight_key] = h;
  }
  const accepted: Array<InsightIn & { fuente: Fuente }> = [];
  const discarded: Discarded[] = [];
  let hipotesisCount = 0;

  for (const ins of insights || []) {
    const key = ins && ins.insight_key;
    if (typeof key !== "string" || key.length === 0) {
      discarded.push({ insight_key: null, motivo: "sin_insight_key" });
      continue;
    }
    const h = byKey[key];
    if (h) {
      if (h.disparado !== true || h.muestra_suficiente !== true) {
        discarded.push({ insight_key: key, motivo: "hecho_no_disparado_o_muestra_insuficiente" });
        continue;
      }
      const numerosOk =
        numEq(ins.valor_observado, h.valor_observado) &&
        numEq(ins.valor_referencia, h.valor_referencia) &&
        String(ins.metrica_clave ?? "") === String(h.metrica_clave ?? "");
      if (!numerosOk) {
        discarded.push({ insight_key: key, motivo: "numeros_no_coinciden_con_hecho" });
        continue;
      }
      accepted.push(Object.assign({}, ins, { fuente: "detector" as Fuente }));
    } else if (key.indexOf("hipotesis_") === 0) {
      const score = ins.score_confianza;
      if (typeof score === "number" && score <= 0.5 && hipotesisCount < 1) {
        hipotesisCount += 1;
        accepted.push(Object.assign({}, ins, { fuente: "hipotesis" as Fuente }));
      } else {
        discarded.push({
          insight_key: key,
          motivo: hipotesisCount >= 1 ? "hipotesis_excede_max_1" : "hipotesis_score_invalido",
        });
      }
    } else {
      discarded.push({ insight_key: key, motivo: "key_no_respaldado_por_hecho" });
    }
  }
  return { accepted, discarded };
}
