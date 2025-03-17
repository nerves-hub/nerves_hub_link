# Debugging

## TLS client errors

If you see the following in your logs:

```text
14:26:06.926 [info]  ['TLS', 32, 'client', 58, 32, 73, 110, 32, 115, 116, 97, 116, 101, 32, 'cipher', 32, 'received SERVER ALERT: Fatal - Unknown CA', 10]
```

This probably indicates that the signing certificate hasn't been uploaded to NervesHub so the device can't be authenticated. Double check that you ran:

```sh
mix nerves_hub.ca_certificate register my-signer.cert
```

Another possibility is that the device wasn't provisioned with the certificate
that's on NervesHub.

See also [NervesHubWeb: Potential SSL Issues](https://github.com/nerves-hub/nerves_hub_web#potential-ssl-issues)
