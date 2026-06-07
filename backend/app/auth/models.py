"""Pydantic models for the auth endpoints."""

from __future__ import annotations

from pydantic import BaseModel, EmailStr, Field


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class UserProfile(BaseModel):
    """Public user view (never includes the password hash)."""

    id: int
    email: str
    created_at: str
    updated_at: str
    connected_brokers: int = 0


class AuthResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserProfile


class LogoutResponse(BaseModel):
    success: bool = True
    message: str = "Logged out."
