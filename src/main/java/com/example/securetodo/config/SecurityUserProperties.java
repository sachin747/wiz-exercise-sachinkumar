package com.example.securetodo.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.security")
public record SecurityUserProperties(
        String userName,
        String userPassword,
        String adminName,
        String adminPassword) {
}
