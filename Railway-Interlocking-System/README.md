# Secunderabad – Lingampalli Railway Interlocking

Files: `app.py` (Streamlit UI), `db.py` (MySQL helpers), `schema.sql` (tables + triggers + seed data), `requirements.txt`.
Put all four in ONE folder.

## Setup
1. Install MySQL 8.0+ and make sure it is running.
2. `pip install -r requirements.txt`
3. Set connection details (Windows: `set`, Mac/Linux: `export`):
   - DB_HOST=localhost
   - DB_USER=root
   - DB_PASSWORD=your_password
   - (optional) DB_PORT=3306, DB_NAME=rail_interlocking
4. `streamlit run app.py`
5. In the sidebar click **(Re)create schema + seed data** (first run only; it wipes the DB).

## Try it
- Route tab: choose Godavari Express, Secunderabad Jn -> Lingampalli, pick an officer, Find paths, Reserve.
- Train control tab: Move train to SC-STPD, then the next blocks one by one, then Leave network from CDNR-LPI.
- Manual reservation `2,4` or `1,9` is rejected by the triggers.
