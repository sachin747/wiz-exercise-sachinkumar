package com.example.securetodo.user;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public class SignupForm {

    @NotBlank(message = "Choose a username")
    @Size(min = 3, max = 40, message = "Username must be 3-40 characters")
    private String username;

    // max = 72: BCrypt silently ignores any bytes past the 72nd, so anything
    // longer wouldn't do what the user thinks it does.
    @NotBlank(message = "Choose a password")
    @Size(min = 8, max = 72, message = "Password must be 8-72 characters")
    private String password;

    public String getUsername() {
        return username;
    }

    public void setUsername(String username) {
        this.username = username;
    }

    public String getPassword() {
        return password;
    }

    public void setPassword(String password) {
        this.password = password;
    }
}
