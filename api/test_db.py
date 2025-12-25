import psycopg2

try:
    conn = psycopg2.connect(
        dbname="runmap",
        user="runmap_user",
        password="fucker",
        host="localhost"
    )
    cur = conn.cursor()
    cur.execute("SELECT PostGIS_Version();")
    version = cur.fetchone()
    print(f"✓ Connected! PostGIS version: {version[0]}")
    cur.close()
    conn.close()
except Exception as e:
    print(f"✗ Error: {e}")
