"""
mitmproxy addon: credential-inject
Intercepts HTTP(S) requests and injects credentials based on YAML rules.

Secrets are resolved via provider shell scripts and cached in process memory.
The agent never sees secret values — they exist only in this proxy process.

Usage with mitmdump:
    mitmdump --listen-port 18080 \
        --set confdir=/path/to/ca \
        --set rules_file=/path/to/credentials.yaml \
        --set providers_dir=/path/to/providers \
        -s credential-inject.py
"""

import fnmatch
import os
import subprocess
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    # Fallback: try to parse simple YAML manually or fail gracefully
    yaml = None

from mitmproxy import ctx, http


class CredentialInjector:
    def __init__(self):
        self.rules = []
        self.passthrough = []
        self.settings = {}
        self.providers_config = {}
        self.cache = {}  # (provider, ref) -> (value, timestamp)
        self.providers_dir = ""

    def load(self, loader):
        loader.add_option("rules_file", str, "", "Path to credential rules YAML")
        loader.add_option("providers_dir", str, "", "Path to provider scripts directory")

    def configure(self, updated):
        if "rules_file" in updated:
            self._load_rules()
        if "providers_dir" in updated:
            self.providers_dir = ctx.options.providers_dir

    def _load_rules(self):
        rules_path = ctx.options.rules_file
        if not rules_path or not os.path.exists(rules_path):
            return

        if yaml is None:
            ctx.log.error("PyYAML not installed — cannot parse rules file")
            return

        with open(rules_path) as f:
            config = yaml.safe_load(f)

        if not config:
            return

        self.settings = config.get("settings", {})
        self.providers_config = config.get("providers", {})

        # Extract HTTP proxy rules
        http_proxy = config.get("http_proxy", {})
        self.rules = http_proxy.get("rules", [])
        self.passthrough = http_proxy.get("passthrough", [])

        ctx.log.info(
            f"Loaded {len(self.rules)} credential rules, "
            f"{len(self.passthrough)} passthrough patterns"
        )

    def _matches_passthrough(self, host: str) -> bool:
        for pattern in self.passthrough:
            if fnmatch.fnmatch(host, pattern):
                return True
        return False

    def _matches_rule(self, rule: dict, flow: http.HTTPFlow) -> bool:
        match = rule.get("match", {})
        host = flow.request.pretty_host
        path = flow.request.path

        if "host" in match:
            if not fnmatch.fnmatch(host, match["host"]):
                return False
        if "path_prefix" in match:
            if not path.startswith(match["path_prefix"]):
                return False
        return True

    def _resolve_secret(
        self, provider_name: str, secret_ref: str, provider_config: dict | None = None
    ) -> str | None:
        cache_ttl = self.settings.get("cache_ttl", 300)
        cache_key = (provider_name, secret_ref)

        # Check cache
        if cache_key in self.cache:
            value, ts = self.cache[cache_key]
            if time.time() - ts < cache_ttl:
                return value

        # Build provider command
        script = os.path.join(self.providers_dir, f"{provider_name}.sh")
        if not os.path.exists(script):
            ctx.log.error(f"Provider script not found: {script}")
            return None

        cmd = [script, "get", secret_ref]

        # Add provider-level config (from providers section)
        if provider_name in self.providers_config:
            for k, v in self.providers_config[provider_name].items():
                cmd.append(f"{k}={v}")

        # Add rule-level config overrides
        if provider_config:
            for k, v in provider_config.items():
                cmd.append(f"{k}={v}")

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                value = result.stdout
                self.cache[cache_key] = (value, time.time())
                return value
            else:
                ctx.log.error(
                    f"Provider {provider_name} failed for {secret_ref}: "
                    f"{result.stderr.strip()}"
                )
                return None
        except subprocess.TimeoutExpired:
            ctx.log.error(f"Provider {provider_name} timed out for {secret_ref}")
            return None
        except Exception as e:
            ctx.log.error(f"Provider {provider_name} error: {e}")
            return None

    def _invalidate_cache(self, provider_name: str, secret_ref: str):
        cache_key = (provider_name, secret_ref)
        self.cache.pop(cache_key, None)

    def _parse_secret_template(self, template: str) -> tuple[str, str]:
        """Parse '{secret:ref}' or '{secret}' templates.

        Returns (template_format, secret_ref_override).
        If template contains {secret:ref}, returns the ref.
        If template contains {secret}, returns empty string (use rule's secret_ref).
        """
        if "{secret:" in template:
            # Extract ref from {secret:ref-name}
            start = template.index("{secret:") + len("{secret:")
            end = template.index("}", start)
            ref = template[start:end]
            return template[:start - len("{secret:")] + "{secret}" + template[end + 1:], ref
        return template, ""

    def request(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host

        # Skip passthrough hosts
        if self._matches_passthrough(host):
            return

        for rule in self.rules:
            if not self._matches_rule(rule, flow):
                continue

            inject = rule.get("inject", {})
            headers = inject.get("headers", {})
            default_provider = self.settings.get("default_provider", "gcp-secrets")

            for header_name, header_template in headers.items():
                # Parse template to extract secret reference
                template, secret_ref_override = self._parse_secret_template(
                    header_template
                )

                secret_ref = secret_ref_override or rule.get("secret_ref", "")
                if not secret_ref:
                    ctx.log.warn(
                        f"No secret_ref for rule '{rule.get('name', 'unnamed')}' "
                        f"header '{header_name}'"
                    )
                    continue

                provider = rule.get("provider", default_provider)
                provider_config = rule.get("provider_config")
                secret = self._resolve_secret(provider, secret_ref, provider_config)

                if secret:
                    value = template.replace("{secret}", secret)
                    flow.request.headers[header_name] = value

    def response(self, flow: http.HTTPFlow):
        # Invalidate cache on 401 if configured
        if (
            flow.response.status_code == 401
            and self.settings.get("retry_on_401", False)
        ):
            default_provider = self.settings.get("default_provider", "gcp-secrets")
            for rule in self.rules:
                if self._matches_rule(rule, flow):
                    inject = rule.get("inject", {})
                    for header_template in inject.get("headers", {}).values():
                        _, secret_ref = self._parse_secret_template(header_template)
                        if secret_ref:
                            provider = rule.get("provider", default_provider)
                            self._invalidate_cache(provider, secret_ref)
                            ctx.log.info(
                                f"Invalidated cache for {provider}/{secret_ref} "
                                f"after 401 from {flow.request.pretty_host}"
                            )


addons = [CredentialInjector()]
