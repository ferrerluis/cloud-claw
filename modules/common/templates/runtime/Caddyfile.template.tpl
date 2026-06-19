{
  email ${acme_email}
}

%{ if openclaw_enabled && openclaw_domain != "" }
${openclaw_domain} {
  basic_auth {
    ${ui_auth_username} __UI_AUTH_HASH__
  }
  reverse_proxy openclaw:18789
}
%{ endif }
%{ if hermes_enabled && hermes_domain != "" }
${hermes_domain} {
  basic_auth {
    ${ui_auth_username} __UI_AUTH_HASH__
  }
  reverse_proxy hermes:9119
}
%{ endif }
%{ if n8n_enabled && n8n_domain != "" }
${n8n_domain} {
%{ if n8n_public_webhooks_enabled }
  @n8n_webhooks path /webhook* /webhook-test*
  reverse_proxy @n8n_webhooks n8n:5678
%{ endif }
  basic_auth {
    ${ui_auth_username} __UI_AUTH_HASH__
  }
  reverse_proxy n8n:5678
}
%{ endif }
