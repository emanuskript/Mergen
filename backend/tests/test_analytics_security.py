import jwt
from starlette.requests import Request

from app.config import settings
from app.routers import analytics


def test_analytics_token_uses_expected_subject_and_algorithm():
    token = analytics._create_token("operator")

    payload = jwt.decode(token, settings.jwt_secret, algorithms=[analytics.ALGORITHM])

    assert payload["sub"] == "operator"
    assert "exp" in payload


def test_login_attempts_are_bounded_and_can_be_cleared(monkeypatch):
    client = "test-client"
    analytics._clear_login_attempts(client)
    monkeypatch.setattr(analytics, "LOGIN_MAX_ATTEMPTS", 2)

    assert analytics._record_login_attempt(client)
    assert analytics._record_login_attempt(client)
    assert not analytics._record_login_attempt(client)

    analytics._clear_login_attempts(client)
    assert analytics._record_login_attempt(client)
    analytics._clear_login_attempts(client)


def test_client_key_ignores_spoofable_leading_forwarded_address():
    request = Request(
        {
            "type": "http",
            "headers": [
                (b"x-forwarded-for", b"198.51.100.40, 203.0.113.25"),
            ],
            "client": ("127.0.0.1", 12345),
        }
    )

    assert analytics._client_key(request) == "203.0.113.25"


def test_client_key_prefers_proxy_supplied_real_ip():
    request = Request(
        {
            "type": "http",
            "headers": [
                (b"x-real-ip", b"203.0.113.99"),
                (b"x-forwarded-for", b"198.51.100.40, 203.0.113.25"),
            ],
            "client": ("127.0.0.1", 12345),
        }
    )

    assert analytics._client_key(request) == "203.0.113.99"
