import { openDb } from "./db.js";

const dbPath = process.env.POINTS_DB_PATH ?? "./data/points.db";
const db = openDb(dbPath);

// Schema and accrual rules are intentionally not defined yet (see docs/TOKENOMICS.md).
const row = db.prepare("select sqlite_version() as version").get() as { version: string };
console.log(`points scaffold ready (sqlite ${row.version}) at ${dbPath}`);
db.close();
