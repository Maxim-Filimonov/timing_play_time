# Web app built with Phoenix (Elixir)

**Status**: accepted

The web app (ADR-0002's core, plus its UI) is built with Phoenix on Elixir, rather than a JS/TS stack. This is a deliberate choice despite both external integrations (Timing, Fibery) being reached via MCP tooling that is JS-native elsewhere in this environment — Phoenix/Elixir is not the obvious default here, so it's worth recording that the choice was intentional rather than assuming it should be "fixed" to match the MCP tooling's language later.

## Consequences

- The Time Source and Persistence plug-in contracts from ADR-0002 are Elixir behaviours (or equivalent), not TS interfaces.
- Calling the Timing and Fibery MCP servers from Elixir requires either an MCP client implementation in Elixir or a thin bridge process — not yet designed.
