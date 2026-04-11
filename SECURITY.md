# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability, please follow these steps:

### 1. Do Not Open a Public Issue

Please **DO NOT** open a public issue on GitHub. This could expose the vulnerability to malicious actors before we have a chance to fix it.

### 2. Contact Us Directly

Send an email to **security@zigmodu.dev** with:

- **Subject**: `[SECURITY] Brief description of the vulnerability`
- **Body**:
  - Detailed description of the vulnerability
  - Steps to reproduce
  - Potential impact
  - Suggested fix (if any)
  - Your contact information for follow-up

### 3. Response Timeline

We will acknowledge receipt of your report within **48 hours** and provide a detailed response within **7 days**.

| Timeframe | Action |
|-----------|--------|
| 48 hours | Acknowledge receipt |
| 7 days | Initial assessment |
| 30 days | Fix or mitigation plan |
| 90 days | Public disclosure (coordinated) |

### 4. Disclosure Policy

We follow a **coordinated disclosure** policy:

1. We work with you to understand and fix the issue
2. We release a patch before public disclosure
3. We credit you in the security advisory (unless you prefer anonymity)
4. We publish a security advisory after the fix is available

## Security Best Practices

### When Using ZigModu

1. **Keep dependencies updated**: Regularly update to the latest version
2. **Validate inputs**: Always validate module inputs
3. **Use least privilege**: Modules should have minimal permissions
4. **Audit dependencies**: Review third-party dependencies
5. **Enable logging**: Monitor for suspicious activity

### For Contributors

1. **No secrets in code**: Never commit API keys, passwords, or tokens
2. **Secure defaults**: Use secure default configurations
3. **Input validation**: Validate all inputs at module boundaries
4. **Error handling**: Don't leak sensitive information in error messages
5. **Memory safety**: Follow Zig's memory safety guidelines

## Known Security Considerations

### Current Limitations

1. **Event Bus**: Events are not encrypted in transit between modules
2. **DI Container**: Type casting bypasses Zig's type safety
3. **Configuration**: JSON configs are not encrypted

### Mitigations

```zig
// Validate event data before processing
fn handleEvent(event: MyEvent) void {
    if (event.user_id == 0) {
        std.log.err("Invalid user_id in event", .{});
        return;
    }
    // Process event...
}

// Validate service retrieval
const db = container.getTyped("database", Database);
if (db == null) {
    std.log.err("Database service not found", .{});
    return error.ServiceNotAvailable;
}
```

## Security Checklist

Before deploying applications using ZigModu:

- [ ] All dependencies are up to date
- [ ] No hardcoded secrets in source code
- [ ] Input validation is implemented
- [ ] Error messages don't leak sensitive info
- [ ] Logging is enabled and monitored
- [ ] Module dependencies are reviewed
- [ ] Configuration files are secured
- [ ] Network communication is encrypted (if applicable)

## Acknowledgments

We thank the following security researchers who have responsibly disclosed vulnerabilities:

*None yet - be the first!*

## Contact

- **Security Email**: security@zigmodu.dev
- **General Issues**: [GitHub Issues](https://github.com/yourusername/zigmodu/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/zigmodu/discussions)

---

Last updated: 2025-04-08