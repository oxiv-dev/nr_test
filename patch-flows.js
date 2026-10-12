const fs = require('fs');

const file = process.argv[2];
const host = process.env.REDIS_HOST || 'redis';
const flows = JSON.parse(fs.readFileSync(file, 'utf8'));

let patched = 0;
for (const n of flows) {
  if (n.type === 'redis-config') {
    n.options = JSON.stringify({ host, port: 6379 });
    n.optionsType = 'json';
    patched++;
  }
}

fs.writeFileSync(file, JSON.stringify(flows, null, 2));
console.log(`patched ${patched} redis-config node(s) -> host=${host}`);
