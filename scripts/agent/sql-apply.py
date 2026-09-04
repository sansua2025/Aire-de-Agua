#!/usr/bin/env python3
"""sql-apply.py — AIR-276. Aplica un archivo .sql a Postgres SIN capa de metacomandos.

┌─ POR QUÉ EXISTE ESTE ARCHIVO ─────────────────────────────────────────────┐
│ El gate ejecuta SQL que trae el PR. Aplicarlo con `psql -f` es ejecución   │
│ de código controlado por el autor del PR: psql interpreta `\\!`, `\\copy`,   │
│ `\\i`, `\\o`… desde un archivo igual que en sesión interactiva, y ni        │
│ `--single-transaction` ni `ON_ERROR_STOP=1` lo desactivan.                 │
│                                                                            │
│ El intento anterior fue escanear los .sql con un lexer propio que          │
│ replicaba la tokenización de psql. Divergió TRES veces, cada una un        │
│ bypass real y reproducido:                                                 │
│   1. el backslash a MITAD de sentencia también ejecuta                     │
│   2. `pg_dump` envuelve todo volcado en `\\restrict`/`\\unrestrict`          │
│   3. `$` es carácter legal DENTRO de un identificador, así que `a$q$` es   │
│      el identificador `a$q$` y NO abre un dollar-quote — el escáner se     │
│      creía dentro de una cadena y se tragaba el metacomando siguiente.     │
│      Dos formas: `SELECT 1 AS a$q$;` y `... ADD COLUMN col_a$$b text;`     │
│      (SQL válido, así que ON_ERROR_STOP tampoco lo paraba). Y una cuarta   │
│      por la etiqueta: `$ñ$…$ñ$` SÍ es dollar-quote para psql (dolq_start   │
│      admite \\200-\\377) y el escáner no lo reconocía.                       │
│                                                                            │
│ El patrón es la lección: cada intento de replicar el lexer de psql         │
│ diverge en algo, y la siguiente divergencia existe aunque no la hayamos    │
│ encontrado. Así que NO se replica. Se quita el lexer del camino: este      │
│ script habla el protocolo de Postgres directamente (psycopg), y ahí `\\!`   │
│ no es un metacomando de nada — es SQL inválido y lo rechaza el SERVIDOR.   │
│ Fail-closed por construcción, sin tokenizador que adivinar.                │
└───────────────────────────────────────────────────────────────────────────┘

Equivalencias con las opciones de psql que sustituye:
  --single-transaction  →  una sola transacción explícita: o entra todo o nada.
  -v ON_ERROR_STOP=1    →  el primer error aborta (excepción) y hace ROLLBACK.
  el error de Postgres  →  se imprime severidad, mensaje, DETAIL, HINT, LINE y
                           el cursor de posición, como los imprime psql.

LO QUE SE PIERDE (dicho, no escondido): psql trocea el archivo en sentencias y
las manda una a una; aquí va el archivo ENTERO en una sola consulta simple. El
servidor lo parsea de una vez y luego ejecuta sentencia por sentencia, así que
una sentencia puede usar lo que creó la anterior (comprobado). Pero una
sentencia que no puede correr dentro de un bloque de transacción (CREATE INDEX
CONCURRENTLY, VACUUM) falla — igual que ya fallaba con --single-transaction, así
que no es una regresión. Y deja de ser cierto que "aplicamos igual que psql":
aplicamos igual que el SERVIDOR, que es la pregunta que el gate quiere contestar.

LECTURA ESTRICTA DEL ARCHIVO (y por qué importa). `psql -f` falla CERRADO ante
bytes que no son UTF-8 válido: `invalid byte sequence for encoding "UTF8"`. La
primera versión de este script leía con errors="replace", así que un
`INSERT … VALUES ('Bogotá')` guardado en latin-1 pasaba en VERDE y guardaba el
carácter sustituido — verde en el gate, rojo en PROD, que es la única dirección
que este gate existe para evitar. Y un NUL era peor: libpq TRUNCA la consulta en
el NUL, así que el gate daba `ok` habiendo ejecutado la mitad del archivo
(comprobado: la tabla anterior al NUL existía y la posterior no). Las dos cosas
son ahora un fallo explícito. Coste real: cero — los 152 .sql del repo son UTF-8
válido y ninguno lleva NUL.

CÓDIGOS DE SALIDA (el gate los distingue; no son intercambiables):
  0  aplicado y confirmado
  1  el ARCHIVO es el problema: SQL inválido, encoding inválido, NUL
  2  falta el driver (psycopg2)
  3  no se pudo CONECTAR — no es culpa de la migración, y decirlo importa:
     antes un puerto muerto se reportaba igual que un SQL roto y el log
     culpaba a la migración de una caída de la base.

Uso: sql-apply.py --dsn <conninfo> --file <archivo.sql>
"""
import argparse
import sys

try:
    import psycopg2
except ImportError:
    sys.stderr.write(
        "sql-apply: falta psycopg2 (paquete python3-psycopg2).\n"
        "El gate NO cae de vuelta a `psql -f`: esa era la vía de ejecución de\n"
        "código del PR que este script existe para cerrar. Sin driver, no se\n"
        "aplica nada y el gate falla.\n")
    sys.exit(2)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--file", required=True)
    args = ap.parse_args()

    with open(args.file, "rb") as fh:
        raw = fh.read()

    # NUL: libpq corta la cadena ahí. Aceptarlo significaría declarar "aplicada"
    # una migración de la que solo se ejecutó el trozo anterior al byte.
    nul = raw.find(b"\x00")
    if nul != -1:
        linea = raw[:nul].count(b"\n") + 1
        sys.stderr.write(
            "sql-apply: el archivo contiene un byte NUL (0x00) en el offset %d, línea %d.\n"
            "  libpq TRUNCA la consulta en el NUL, así que aplicarlo ejecutaría solo la\n"
            "  parte anterior y el gate lo daría por bueno. Se rechaza el archivo entero.\n"
            "  Un .sql de migración no necesita bytes NUL: quítalo.\n" % (nul, linea))
        return 1

    # UTF-8 ESTRICTO, como psql. Un archivo en latin-1 debe morir aquí, no
    # colarse con caracteres sustituidos.
    try:
        sql = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        linea = raw[: exc.start].count(b"\n") + 1
        crudo = " ".join("0x%02x" % b for b in raw[exc.start: exc.start + 3])
        sys.stderr.write(
            "sql-apply: el archivo no es UTF-8 válido (línea %d, offset %d): %s\n"
            "  %s\n"
            "  Es el mismo rechazo que daría psql (\"invalid byte sequence for encoding\n"
            "  \"UTF8\"\"). Reguarda el archivo en UTF-8; si pasara con los bytes\n"
            "  sustituidos, el gate daría verde y PROD fallaría.\n"
            % (linea, exc.start, crudo, exc.reason))
        return 1

    if not sql.strip():
        return 0

    # La conexión va en su propio try: un fallo aquí NO es culpa del archivo, y
    # el gate necesita poder distinguirlo (rc 3) para no culpar a la migración.
    try:
        conn = psycopg2.connect(args.dsn)
    except psycopg2.Error as exc:
        sys.stderr.write("sql-apply: no se pudo conectar al destino: %s\n"
                         % str(exc).strip())
        return 3

    try:
        conn.autocommit = False          # ← --single-transaction
        # Explícito: el archivo se validó como UTF-8, así que el servidor debe
        # interpretarlo como UTF-8. Nada de heredar un client_encoding ambiguo.
        conn.set_client_encoding("UTF8")
        with conn.cursor() as cur:
            # OJO: se pasa UNA sola cadena y NINGÚN parámetro. Con vars=None
            # psycopg2 no interpola, así que un `%` del SQL (LIKE 'pg\_%',
            # to_char(...,'99%')) llega intacto y no se confunde con un
            # marcador de posición.
            cur.execute(sql)
        conn.commit()                    # ← o entra todo, o nada
        return 0
    except psycopg2.Error as exc:
        if conn is not None:
            try:
                conn.rollback()          # ← ON_ERROR_STOP=1
            except psycopg2.Error:
                pass
        d = exc.diag
        sev = (d.severity or "ERROR") if d else "ERROR"
        msg = (d.message_primary if d and d.message_primary else str(exc).strip())
        sys.stderr.write("%s:  %s\n" % (sev, msg))
        # SQLSTATE explícito: el control positivo del gate exige ver 42601
        # (syntax_error) para dar por demostrada la contención — un rc=1
        # cualquiera no prueba que el SERVIDOR haya visto el canario.
        if exc.pgcode:
            sys.stderr.write("SQLSTATE:  %s\n" % exc.pgcode)
        if d and d.message_detail:
            sys.stderr.write("DETAIL:  %s\n" % d.message_detail)
        if d and d.message_hint:
            sys.stderr.write("HINT:  %s\n" % d.message_hint)
        # Posición → misma pista "LINE n: …^" que da psql.
        if d and d.statement_position:
            pos = int(d.statement_position)
            head = sql[: pos - 1]
            line_no = head.count("\n") + 1
            line_start = head.rfind("\n") + 1
            line_end = sql.find("\n", pos - 1)
            line = sql[line_start: line_end if line_end != -1 else len(sql)]
            sys.stderr.write("LINE %d: %s\n" % (line_no, line))
            sys.stderr.write("%s^\n" % (" " * (len("LINE %d: " % line_no) + (pos - 1 - line_start))))
        if d and d.context:
            sys.stderr.write("CONTEXT:  %s\n" % d.context)
        # Pista dirigida: el error típico de quien pegó un metacomando de psql.
        if "\\" in msg:
            sys.stderr.write(
                'PISTA:  si eso es un metacomando de psql (\\!, \\copy, \\i, \\o …),\n'
                '        no se admite: el gate aplica el SQL contra el servidor, sin\n'
                '        capa de metacomandos, y para el servidor un backslash suelto\n'
                '        es un error de sintaxis. Usa SQL puro.\n')
        return 1
    except Exception as exc:                                  # noqa: BLE001
        sys.stderr.write("sql-apply: %s\n" % exc)
        return 1
    finally:
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    sys.exit(main())
