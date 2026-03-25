#!/bin/bash
#docker volume create n8n_data
docker run --restart=always -it --name n8n -e WEBHOOK_URL=https://automation.nflsdigital.com -e N8N_PROXY_HOPS=1 -p 5678:5678 -v n8n_data:/home/node/.n8n docker.n8n.io/n8nio/n8n
