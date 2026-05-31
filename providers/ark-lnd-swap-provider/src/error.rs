use anyhow::anyhow;
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};

use crate::{models::ErrorResponse, store::StoreError};

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    error: anyhow::Error,
}

impl ApiError {
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            error: anyhow!(message.into()),
        }
    }

    pub fn internal(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            error,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(ErrorResponse {
                error: self.error.to_string(),
            }),
        )
            .into_response()
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self::internal(error)
    }
}

impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::NotFound(id) => Self {
                status: StatusCode::NOT_FOUND,
                error: anyhow!("swap not found: {id}"),
            },
            StoreError::Internal(error) => Self::internal(error),
            StoreError::WriterClosed => Self::internal(anyhow!("store writer task is closed")),
        }
    }
}
