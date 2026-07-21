# Deferred Work

## Plugin platform

- **Strict duplicate-key JSON parsing** — Before accepting public plugins, replace Foundation's normalized JSON decoding boundary with a parser that rejects duplicate object keys. Source: `spec-plugin-phase-0-validation.md`; deferred because Phase 0 validates architecture with trusted fixtures and adding a parser or dependency exceeds the approved boundary.
- **Broker caller authentication** — Before public distribution, validate each XPC connection using its audit token and expected Developer ID/code signature. Source: `spec-plugin-phase-0-validation.md`; deferred because Phase 0 uses ad-hoc signing and the spike is not embedded in the production app.
