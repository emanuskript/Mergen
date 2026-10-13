"""Analytics endpoints with JWT authentication and bounded login attempts."""

from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
import secrets
import threading
import time

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
import jwt
from jwt import InvalidTokenError

from app.config import settings
from app.schemas.analytics import LoginRequest, LoginResponse
from app.services.analytics_service import get_analytics_data

router = APIRouter(tags=["analytics"])
security = HTTPBearer()

ALGORITHM = "HS256"
LOGIN_WINDOW_SECONDS = 5 * 60
LOGIN_MAX_ATTEMPTS = 10
_login_attempts: dict[str, deque[float]] = defaultdict(deque)
_login_lock = threading.Lock()


def _client_key(request: Request) -> str:
    """Use only the proxy-appended address, never a spoofable leading value."""
    real_ip = request.headers.get("x-real-ip", "").strip()
    if real_ip:
        return real_ip
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.rsplit(",", 1)[-1].strip()
    return request.client.host if request.client else "unknown"


def _record_login_attempt(client_key: str) -> bool:
    now = time.monotonic()
    cutoff = now - LOGIN_WINDOW_SECONDS
    with _login_lock:
        for key in list(_login_attempts):
            attempts = _login_attempts[key]
            while attempts and attempts[0] < cutoff:
                attempts.popleft()
            if not attempts:
                del _login_attempts[key]

        attempts = _login_attempts[client_key]
        if len(attempts) >= LOGIN_MAX_ATTEMPTS:
            return False
        attempts.append(now)
        return True


def _clear_login_attempts(client_key: str) -> None:
    with _login_lock:
        _login_attempts.pop(client_key, None)


def _create_token(username: str) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.jwt_expiry_minutes)
    return jwt.encode(
        {"sub": username, "exp": expire},
        settings.jwt_secret,
        algorithm=ALGORITHM,
    )


def _verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    try:
        payload = jwt.decode(credentials.credentials, settings.jwt_secret, algorithms=[ALGORITHM])
        username = payload.get("sub")
        if username is None:
            raise HTTPException(status_code=401, detail="Invalid token.")
        return username
    except InvalidTokenError:
        raise HTTPException(status_code=401, detail="Invalid or expired token.")


@router.post("/analytics/login")
async def analytics_login(body: LoginRequest, request: Request):
    client_key = _client_key(request)
    if not _record_login_attempt(client_key):
        raise HTTPException(status_code=429, detail="Too many login attempts. Try again later.")

    username_ok = secrets.compare_digest(
        body.username.encode("utf-8"), settings.analytics_username.encode("utf-8")
    )
    password_ok = secrets.compare_digest(
        body.password.encode("utf-8"), settings.analytics_password.encode("utf-8")
    )
    if username_ok and password_ok:
        _clear_login_attempts(client_key)
        return LoginResponse(token=_create_token(body.username))
    raise HTTPException(status_code=401, detail="Invalid credentials.")


@router.get("/analytics/data")
async def analytics_data(days: int = 30, _user: str = Depends(_verify_token)):
    return get_analytics_data(days)
