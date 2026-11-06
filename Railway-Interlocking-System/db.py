"""Database layer for the Rail Interlocking app (MySQL 8+)."""
import os
from pathlib import Path

import mysql.connector
from mysql.connector import Error

DB_NAME = os.getenv("DB_NAME", "rail_interlocking")


def _config(with_db=True):
    cfg = {
        "host": os.getenv("DB_HOST", "localhost"),
        "port": int(os.getenv("DB_PORT", "3306")),
        "user": os.getenv("DB_USER", "root"),
        "password": os.getenv("DB_PASSWORD", "Dinesh#@2004"),
        "autocommit": False,
    }
    if with_db:
        cfg["database"] = DB_NAME
    return cfg


def get_conn(with_db=True):
    return mysql.connector.connect(**_config(with_db))


# ------------------------------------------------------------ basic helpers
def query(sql, params=None):
    """Run a SELECT and return a list of dicts."""
    conn = get_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute(sql, params or ())
        return cur.fetchall()
    finally:
        conn.close()


def execute_tx(sql, params=None):
    """Run one write statement in its own transaction -> (ok, message)."""
    conn = get_conn()
    try:
        cur = conn.cursor()
        cur.execute(sql, params or ())
        conn.commit()
        return True, "OK"
    except Error as e:
        conn.rollback()
        return False, e.msg
    finally:
        conn.close()


def _split_script(text):
    """Split a SQL script into statements, honouring DELIMITER lines."""
    delim, buf, out = ";", [], []
    for line in text.splitlines():
        s = line.strip()
        if s.upper().startswith("DELIMITER "):
            delim = s.split(None, 1)[1]
            continue
        if not buf and (not s or s.startswith("--")):
            continue
        buf.append(line)
        if s.endswith(delim):
            stmt = "\n".join(buf).rstrip()
            stmt = stmt[: -len(delim)].strip()
            if stmt:
                out.append(stmt)
            buf = []
    return out


def run_script(path):
    """Execute a .sql file (schema + triggers + seed data)."""
    p = Path(path)
    if not p.is_absolute():
        p = Path(__file__).parent / p
    statements = _split_script(p.read_text(encoding="utf-8"))
    conn = get_conn(with_db=False)
    try:
        cur = conn.cursor()
        for stmt in statements:
            cur.execute(stmt)
        conn.commit()
    finally:
        conn.close()


# ------------------------------------------------------------ path finding
def find_paths(src, dst, limit=5):
    """Recursive CTE: every simple path of FREE blocks src -> dst, shortest first."""
    sql = """
    WITH RECURSIVE edges AS (
        SELECT block_id, from_junction AS a, to_junction AS z, length_m, status FROM track_blocks
        UNION ALL
        SELECT block_id, to_junction,   from_junction,        length_m, status FROM track_blocks
    ),
    walk (junction, path_j, path_b, hops, dist) AS (
        SELECT CAST(%s AS SIGNED),
               CAST(CONCAT(',', %s, ',') AS CHAR(500)),
               CAST('' AS CHAR(500)),
               CAST(0 AS SIGNED),
               CAST(0 AS SIGNED)
        UNION ALL
        SELECT e.z,
               CONCAT(w.path_j, e.z, ','),
               CONCAT(w.path_b, IF(w.path_b = '', '', ','), e.block_id),
               w.hops + 1,
               w.dist + e.length_m
          FROM walk w
          JOIN edges e ON e.a = w.junction
         WHERE e.status = 'FREE'
           AND w.junction <> %s
           AND LOCATE(CONCAT(',', e.z, ','), w.path_j) = 0
    )
    SELECT path_b, hops, dist FROM walk
     WHERE junction = %s AND path_b <> ''
     ORDER BY dist, hops
     LIMIT %s
    """
    rows = query(sql, (src, src, dst, dst, limit))
    return [{"blocks": [int(x) for x in r["path_b"].split(",")],
             "hops": int(r["hops"]), "dist": int(r["dist"])} for r in rows]


# ------------------------------------------------------------ reservation
def reserve(train_id, src, dst, candidates):
    """Try each candidate block list in turn.

    One transaction; each candidate runs behind a SAVEPOINT so a trigger
    rejection rolls back only that candidate and the next-best path is tried.
    """
    result = {"ok": False, "reservation_id": None, "blocks": None, "failures": []}
    conn = get_conn()
    try:
        cur = conn.cursor()
        for blocks in candidates:
            cur.execute("SAVEPOINT candidate")
            try:
                cur.execute(
                    "INSERT INTO route_reservations (train_id, src_junction, dst_junction) "
                    "VALUES (%s,%s,%s)", (train_id, src, dst))
                rid = cur.lastrowid
                for seq, b in enumerate(blocks, 1):
                    cur.execute(
                        "INSERT INTO route_blocks (reservation_id, seq, block_id) "
                        "VALUES (%s,%s,%s)", (rid, seq, b))
                conn.commit()
                result.update(ok=True, reservation_id=rid, blocks=blocks)
                return result
            except Error as e:
                cur.execute("ROLLBACK TO SAVEPOINT candidate")
                result["failures"].append((blocks, e.msg))
        # nothing worked: keep an audit trail of the rejections
        for blocks, msg in result["failures"]:
            cur.execute(
                "INSERT INTO interlocking_log (train_id, event, detail) VALUES (%s,%s,%s)",
                (train_id, "ROUTE_REJECTED", f"{blocks}: {msg}"[:255]))
        conn.commit()
        return result
    except Error as e:
        conn.rollback()
        result["failures"].append((candidates, e.msg))
        return result
    finally:
        conn.close()


# ------------------------------------------------------------ train control
def move_train(train_id, block_id):
    """Move a train to a block (or out of the network when block_id is None)."""
    ok, msg = execute_tx("UPDATE trains SET current_block_id=%s WHERE train_id=%s",
                         (block_id, train_id))
    if ok:
        msg = "Train left the network" if block_id is None else "Train moved"
    return ok, msg


def release_route(train_id):
    """Cancel the train's ACTIVE route and free its RESERVED blocks."""
    conn = get_conn()
    try:
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT reservation_id FROM route_reservations "
                    "WHERE train_id=%s AND status='ACTIVE'", (train_id,))
        row = cur.fetchone()
        if not row:
            return False, "No active route to release"
        rid = row["reservation_id"]
        cur.execute("UPDATE route_reservations SET status='RELEASED' WHERE reservation_id=%s", (rid,))
        cur.execute("UPDATE track_blocks SET status='FREE' WHERE status='RESERVED' AND block_id IN "
                    "(SELECT block_id FROM route_blocks WHERE reservation_id=%s)", (rid,))
        cur.execute("INSERT INTO interlocking_log (train_id, event, detail) VALUES (%s,%s,%s)",
                    (train_id, "ROUTE_RELEASED", f"Reservation #{rid} released"))
        conn.commit()
        return True, f"Reservation #{rid} released"
    except Error as e:
        conn.rollback()
        return False, e.msg
    finally:
        conn.close()
