package com.example.securetodo.user;

import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

/**
 * A self-registered account, created via POST /signup.
 *
 * Separate from the two seeded demo accounts (todo-user / todo-admin), which
 * stay in-memory exactly as before -- see SecurityConfig. This document only
 * ever holds a BCrypt hash, never a plaintext password.
 */
@Document(collection = "users")
public class AppUser {

    @Id
    private String id;

    // unique = true: MongoDB itself rejects a duplicate username as a backstop,
    // in case two signups race between UserService's existsByUsername() check
    // and the save() below.
    @Indexed(unique = true)
    private String username;

    private String password;

    protected AppUser() {
    }

    public AppUser(String username, String password) {
        this.username = username;
        this.password = password;
    }

    public String getUsername() {
        return username;
    }

    public String getPassword() {
        return password;
    }
}
