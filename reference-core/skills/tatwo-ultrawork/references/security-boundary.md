# Security Boundary

This skill supplies workflow guidance only. It does not supply provider access, shell execution, file mutation, sockets, browser control, device control, installation, deployment, or secret storage.

A runtime connector must default to denied permissions, use an explicit working root, avoid public listeners, isolate provider configuration, reject traversal and unsafe symlinks, cap input and output, supervise all child processes, and make irreversible effects separately visible to the user.
