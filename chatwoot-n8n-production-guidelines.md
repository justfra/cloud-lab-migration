# Chatwoot + n8n: Demo-to-Production Guidelines

## Executive Summary

Your current workflow is good for a live demo and fast iteration. It is not a safe long-term production pattern yet because routing logic, IDs, and behavioral rules are hardcoded directly in nodes.

For production, use a config-driven architecture, strict credential management, webhook trust validation, and observability so changes are low risk and reversible.

## What Is Fine In A Demo

- Hardcoded assignee IDs to move fast
- Embedded prompt/copy directly in a Code node
- One workflow handling ingest + routing + response in one chain
- Manual testing via webhook calls

## What Is Not Fine For Production

- Hardcoded IDs (`assignee_id`, account IDs, inbox IDs)
- Hardcoded endpoint domains in multiple nodes
- Secrets in workflow JSON or inline headers
- No idempotency guard for duplicate webhook events
- No centralized error workflow or alerting
- No explicit environment split (dev/stage/prod)

## Production Architecture (Recommended)

### 1) Configuration Layer

Store changing values outside code:

- Agent routing map (`surf -> bruno`, `cozinhar -> francesco`)
- Agent IDs per environment
- Prompt/copy templates
- Confidence thresholds
- Feature flags (auto-assign on/off)

Preferred storage options:

- n8n Variables (simple)
- n8n Data Store (small dynamic config)
- External DB table (best for scale/governance)

### 2) Credentials and Secrets

- Keep Chatwoot token in n8n credentials only
- Keep OpenAI key in n8n credentials only
- Never paste API keys into Code/HTTP body/header fields
- Rotate credentials on a schedule and after incidents

### 3) Event Trust and Safety

- Validate webhook authenticity (signature/HMAC where available)
- Process only expected event types (`message_created`, incoming)
- Ignore bot/self/system events
- Add idempotency key check (message ID + timestamp) to avoid duplicates

### 4) Workflow Composition

Split into reusable workflows:

- Workflow A: Ingest + guardrails + normalization
- Workflow B: AI decision + conversational response
- Workflow C: Assignment + labels + private note + audit log
- Workflow D: Error handler + alerting

This reduces blast radius and makes updates safer.

### 5) Reliability

- Use retries with backoff on external HTTP nodes
- Add explicit failure branches for OpenAI/Chatwoot outages
- Add fallback response if AI is unavailable
- Persist key outputs for audit/debug (route, confidence, assignee, final message)

### 6) Observability

Track and review weekly:

- First response time
- Auto-routing accuracy
- Human handoff rate
- Unanswered conversation count
- Estimated hours saved/month
- Estimated cost saved/month

## Security Checklist

- [ ] No secrets in workflow JSON
- [ ] Credentials scoped to least privilege
- [ ] Webhook endpoint is private/obscure and validated
- [ ] n8n and Chatwoot behind TLS
- [ ] Backup + restore tested
- [ ] API keys rotated and documented

## Go-Live Checklist

- [ ] Separate dev/stage/prod workflows
- [ ] Config values externalized
- [ ] Error workflow enabled with alerts
- [ ] Rate limits tested
- [ ] Duplicate webhook handling tested
- [ ] Runbook written for support team

## Practical Implementation Pattern

For your use case, keep the playful surface (`surf` / `cozinhar`) but make internals robust:

1. Normalize inbound message payload
2. Use AI to classify lane + craft response + confidence
3. If confidence high, assign to mapped agent from config
4. Send customer response
5. Post private note with summary + next action
6. Log decision metadata for KPI reporting

This preserves the demo wow-effect while meeting production hygiene standards.
