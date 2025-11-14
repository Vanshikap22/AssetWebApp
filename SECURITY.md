# Security Policy
We are committed to keeping this application, its users, and its data secure.
This includes securing the codebase, APIs, backend services, and the cloud environment used by the project.

This document explains the security practices developers should follow.
## Supported Versions

This section to tell about which versions of your project are
currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 5.1.x   | :white_check_mark: |
| 5.0.x   | :x:                |
| 4.0.x   | :white_check_mark: |
| < 4.0   | :x:                |

Anyone contributing to this project should follow these simple rules:

 Don’t Commit Secrets
Do not upload:
Passwords
API keys
Azure/AWS keys
Database strings
Use environment variables or secure storage instead.

Use Secure Coding Practices

Validate and sanitize all inputs
Apply proper authentication and authorization
Use HTTPS for all communications
Avoid unsafe libraries or deprecated packages

Secure Your Development Environment

Enable 2FA on GitHub
Use strong passwords
Keep systems updated
Do not work on unsecured networks unless using VPN
