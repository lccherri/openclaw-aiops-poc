"""Custom NeMo Guardrails actions: deterministic, regex-based checks (no GPU needed)."""
import re

from nemoguardrails.actions import action

SENSITIVE_PATTERNS = [
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",                  # private keys
    r"\bsha256~[A-Za-z0-9_-]{20,}",                         # OpenShift OAuth tokens
    r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.",        # JWT / SA tokens
    r"\b(AKIA|ASIA)[A-Z0-9]{16}\b",                          # AWS access keys
    r"\bsk-[A-Za-z0-9]{20,}",                                # API keys (OpenAI style)
    r"(?i)\b(password|passwd|secret|api[_-]?key)\s*[:=]\s*\S{6,}",
    r"\b\d{3}\.\d{3}\.\d{3}-\d{2}\b",                        # CPF (BR personal id)
    r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",   # e-mail addresses
]

INJECTION_PATTERNS = [
    r"(?i)ignore (all|any|the)? ?(previous|prior|above)? ?instructions",
    r"(?i)disregard (your|the) (rules|instructions|system prompt)",
    r"(?i)(delete|remove|drop) (the )?(namespace|project|cluster)",
    r"(?i)oc delete (ns|namespace|project)",
    r"(?i)kubectl delete (ns|namespace)",
    r"(?i)you are now (in )?(developer|admin|god) mode",
]


def _match(patterns, text):
    return any(re.search(p, text or "") for p in patterns)


@action(name="detect_sensitive_data")
async def detect_sensitive_data(text: str = "") -> bool:
    return _match(SENSITIVE_PATTERNS, text)


@action(name="detect_prompt_injection")
async def detect_prompt_injection(text: str = "") -> bool:
    return _match(INJECTION_PATTERNS, text)
