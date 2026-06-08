const { Client } = require('pg');
const client = new Client({
  host: 'localhost',
  port: 5433,
  user: 'grantos',
  password: 'grantos_secret_2025',
  database: 'grantos_service'
});
async function run() {
  await client.connect();
  const res = await client.query(`SELECT * FROM grants ORDER BY created_at DESC LIMIT 5;`);
  console.log(JSON.stringify(res.rows, null, 2));
  await client.end();
}
run().catch(console.error);
