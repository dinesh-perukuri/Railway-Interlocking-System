import pandas as pd
import streamlit as st
import db

st.set_page_config(page_title="Rail Interlocking", page_icon="🚆", layout="wide")
st.title("🚆 Secunderabad – Lingampalli Signal & Route Interlocking")

with st.sidebar:
    st.header("Database")
    if st.button("⚠️ (Re)create schema + seed data"):
        try:
            db.run_script("schema.sql")
            st.success("Database rebuilt")
        except Exception as e:
            st.error(e)
    st.caption("Set DB_HOST / DB_USER / DB_PASSWORD env vars.")

try:
    junctions = db.query("SELECT * FROM junctions ORDER BY junction_id")
except Exception as e:
    st.error(f"Cannot reach database ({e}). Use the sidebar button to create it.")
    st.stop()

jname = {j["junction_id"]: j["name"] for j in junctions}
blocks = db.query("SELECT * FROM track_blocks ORDER BY block_id")
trains = db.query("SELECT t.*, b.name AS block FROM trains t LEFT JOIN track_blocks b "
                  "ON b.block_id=t.current_block_id ORDER BY train_id")
tname = {t["train_id"]: t["name"] for t in trains}
COLORS = {"FREE": "green", "RESERVED": "orange", "OCCUPIED": "red", "OUT_OF_SERVICE": "gray"}

STAFF_SQL = """SELECT s.staff_id, s.name, s.role, j.name AS station, s.shift, s.phone,
                      m.name AS reports_to
               FROM station_staff s
               JOIN junctions j ON j.junction_id = s.junction_id
               LEFT JOIN station_staff m ON m.staff_id = s.reports_to
               ORDER BY s.junction_id, FIELD(s.role,'STATION_MASTER','ASSISTANT_STATION_MASTER','POINTSMAN'), s.name"""
staff = db.query(STAFF_SQL)
# Only station masters / assistants can authorise a route or train movement
officers = [s for s in staff if s["role"] in ("STATION_MASTER", "ASSISTANT_STATION_MASTER")]


def officer_label(s):
    role = "SM" if s["role"] == "STATION_MASTER" else "ASM"
    return f'{s["name"]} ({role}, {s["station"]}, {s["shift"]})'


def log_auth(train_id, action, officer):
    """Record which officer authorised an action in the audit log."""
    db.execute_tx("INSERT INTO interlocking_log (train_id, event, detail) VALUES (%s,%s,%s)",
                  (train_id, "AUTHORISED", f'{action} authorised by {officer_label(officer)}'))


tab_map, tab_route, tab_ctrl, tab_staff, tab_log = st.tabs(
    ["🗺️ Network", "🧭 Find & reserve route", "🚂 Train control",
     "👮 Station staff", "📜 Audit log"])

# ------------------------------------------------------------------ network
with tab_map:
    dot = "graph G { rankdir=LR; node [shape=box, style=rounded];\n"
    for b in blocks:
        dot += (f'"{jname[b["from_junction"]]}" -- "{jname[b["to_junction"]]}" '
                f'[label="{b["name"]} ({b["status"]})", color={COLORS[b["status"]]}, penwidth=3];\n')
    st.graphviz_chart(dot + "}")
    c1, c2 = st.columns(2)
    c1.subheader("Blocks")
    c1.dataframe(pd.DataFrame(blocks), hide_index=True, use_container_width=True)
    c2.subheader("Trains")
    c2.dataframe(pd.DataFrame(trains)[["name", "block"]], hide_index=True, use_container_width=True)
    st.subheader("Maintenance (tests the block state-machine trigger)")
    m1, m2, m3 = st.columns([2, 2, 1])
    mb = m1.selectbox("Block", blocks, format_func=lambda b: f'{b["name"]} [{b["status"]}]')
    ms = m2.selectbox("New status", list(COLORS))
    if m3.button("Apply"):
        ok, msg = db.execute_tx("UPDATE track_blocks SET status=%s WHERE block_id=%s",
                                (ms, mb["block_id"]))
        (st.success if ok else st.error)(msg)
        st.rerun() if ok else None

# ------------------------------------------------------------------ routing
with tab_route:
    auth = st.selectbox("Authorised by (Station Master / Assistant)", officers,
                        format_func=officer_label, key="auth_route")
    c1, c2, c3 = st.columns(3)
    train = c1.selectbox("Train", trains, format_func=lambda t: t["name"])
    src = c2.selectbox("From", junctions, format_func=lambda j: j["name"])
    dst = c3.selectbox("To", junctions, index=len(junctions) - 1,  # Lingampalli
                       format_func=lambda j: j["name"])
    if st.button("Find non-conflicting paths (recursive CTE)"):
        st.session_state.paths = db.find_paths(src["junction_id"], dst["junction_id"])
    paths = st.session_state.get("paths", [])
    if paths:
        st.dataframe(pd.DataFrame([{"blocks": " → ".join(db.query(
            "SELECT name FROM track_blocks WHERE block_id=%s", (b,))[0]["name"] for b in p["blocks"]),
            "hops": p["hops"], "distance_m": p["dist"]} for p in paths]), hide_index=True)
        if st.button("Reserve (transaction + SAVEPOINT fallback to next-best path)"):
            res = db.reserve(train["train_id"], src["junction_id"], dst["junction_id"],
                             [p["blocks"] for p in paths])
            if res["ok"]:
                st.success(f'Reservation #{res["reservation_id"]} granted: blocks {res["blocks"]}')
                log_auth(train["train_id"], f'Route reservation #{res["reservation_id"]}', auth)
            else:
                st.error("No candidate route could be reserved")
            for b, m in res["failures"]:
                st.warning(f"Rolled back to savepoint — {b}: {m}")
    elif "paths" in st.session_state:
        st.info("No free, switch-legal path exists between those junctions.")
    st.divider()
    st.caption("Bypass the pathfinder to watch the triggers reject bad routes (e.g. `2,4` or `1,9`).")
    manual = st.text_input("Manual block id sequence", "1,2,3")
    if st.button("Force manual reservation"):
        try:
            ids = [int(x) for x in manual.split(",")]
            res = db.reserve(train["train_id"], src["junction_id"], dst["junction_id"], [ids])
            if res["ok"]:
                st.success(f'Granted #{res["reservation_id"]}')
                log_auth(train["train_id"], f'Manual reservation #{res["reservation_id"]}', auth)
            for b, m in res["failures"]:
                st.error(f"Rejected by trigger: {m}")
        except ValueError:
            st.error("Enter comma-separated integers")

# ------------------------------------------------------------------ control
with tab_ctrl:
    auth_c = st.selectbox("Authorised by (Station Master / Assistant)", officers,
                          format_func=officer_label, key="auth_ctl")
    t = st.selectbox("Train ", trains, format_func=lambda x: x["name"], key="ctl")
    route = db.query("""SELECT rb.seq, b.name AS block, b.status, rb.cleared FROM route_reservations r
                        JOIN route_blocks rb USING (reservation_id) JOIN track_blocks b USING (block_id)
                        WHERE r.train_id=%s AND r.status='ACTIVE' ORDER BY rb.seq""", (t["train_id"],))
    st.write("**Active route:**" if route else "_No active route_")
    if route:
        st.dataframe(pd.DataFrame(route), hide_index=True)
    target = st.selectbox("Move to block (any block — triggers will police it)", blocks,
                          format_func=lambda b: b["name"])
    a, b_, c_ = st.columns(3)
    if a.button("Move train"):
        ok, msg = db.move_train(t["train_id"], target["block_id"])
        (st.success if ok else st.error)(msg)
        if ok:
            log_auth(t["train_id"], f'Move to {target["name"]}', auth_c)
    if b_.button("Leave network"):
        ok, msg = db.move_train(t["train_id"], None)
        (st.success if ok else st.error)(msg)
        if ok:
            log_auth(t["train_id"], "Leave network", auth_c)
    if c_.button("Release route"):
        ok, msg = db.release_route(t["train_id"])
        (st.success if ok else st.error)(msg)
        if ok:
            log_auth(t["train_id"], "Release route", auth_c)

# ------------------------------------------------------------------ staff
with tab_staff:
    st.subheader("Station Masters, Assistants & Pointsmen")
    roles = ["ALL", "STATION_MASTER", "ASSISTANT_STATION_MASTER", "POINTSMAN"]
    f1, f2 = st.columns(2)
    role_f = f1.selectbox("Role", roles)
    stn_f = f2.selectbox("Station", [{"junction_id": 0, "name": "ALL"}] + junctions,
                         format_func=lambda j: j["name"])
    view = [s for s in staff
            if (role_f == "ALL" or s["role"] == role_f)
            and (stn_f["name"] == "ALL" or s["station"] == stn_f["name"])]
    st.dataframe(pd.DataFrame(view), hide_index=True, use_container_width=True)

    with st.expander("➕ Add staff member"):
        n = st.text_input("Name")
        r = st.selectbox("Role ", roles[1:], key="new_role")
        j = st.selectbox("Station ", junctions, format_func=lambda x: x["name"], key="new_stn")
        sh = st.selectbox("Shift", ["MORNING", "EVENING", "NIGHT"])
        ph = st.text_input("Phone")
        sm_here = [s for s in staff if s["role"] == "STATION_MASTER" and s["station"] == j["name"]]
        boss = None
        if r != "STATION_MASTER" and sm_here:
            boss = st.selectbox("Reports to", sm_here, format_func=lambda s: s["name"])
        if st.button("Save staff member") and n.strip():
            ok, msg = db.execute_tx(
                "INSERT INTO station_staff (name, role, junction_id, shift, phone, reports_to) "
                "VALUES (%s,%s,%s,%s,%s,%s)",
                (n.strip(), r, j["junction_id"], sh, ph, boss["staff_id"] if boss else None))
            (st.success if ok else st.error)(msg)
            st.rerun() if ok else None

# ------------------------------------------------------------------ log
with tab_log:
    st.dataframe(pd.DataFrame(db.query(
        "SELECT ts, train_id, event, detail FROM interlocking_log ORDER BY log_id DESC LIMIT 200")),
        hide_index=True, use_container_width=True)
