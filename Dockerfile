FROM nodered/node-red:latest

RUN npm install --omit=dev node-red-contrib-redis@1.4.0

COPY --chown=node-red:node-red flows.json /data/flows.json
COPY --chown=node-red:node-red patch-flows.js /tmp/patch-flows.js
RUN node /tmp/patch-flows.js /data/flows.json
