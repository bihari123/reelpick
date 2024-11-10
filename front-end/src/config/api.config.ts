// src/config/api.config.ts

const API_BASE_URL =
  process.env.REACT_APP_API_BASE_URL || "http://localhost:3000/api";

export const API_ENDPOINTS = {
  UPLOAD: {
    INITIALIZE: `${API_BASE_URL}/upload/initialize`,
    CHUNK: `${API_BASE_URL}/upload/chunk`,
    VERIFY: `${API_BASE_URL}/upload/verify`,
  },
};

export const API_CONFIG = {
  TIMEOUT: 30000, // 30 seconds
  HEADERS: {
    Accept: "application/json",
  },
  withCredentials: true,
};
