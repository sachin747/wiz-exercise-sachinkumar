package com.example.securetodo.todo;

import java.time.Instant;

import org.springframework.data.annotation.Id;
import org.springframework.data.annotation.Version;
import org.springframework.data.mongodb.core.index.Indexed;
import org.springframework.data.mongodb.core.mapping.Document;

@Document(collection = "todos")
public class Todo {

    @Id
    private String id;

    private String title;

    private String description;

    private boolean completed;

    @Indexed
    private String owner;

    private Instant createdAt;

    private Instant updatedAt;

    @Version
    private Long version;

    protected Todo() {
    }

    private Todo(String title, String description, String owner, Instant now) {
        this.title = title;
        this.description = description;
        this.owner = owner;
        this.createdAt = now;
        this.updatedAt = now;
    }

    public static Todo create(String title, String description, String owner) {
        return new Todo(title, description, owner, Instant.now());
    }

    public void toggle() {
        this.completed = !this.completed;
        this.updatedAt = Instant.now();
    }

    public String getId() {
        return id;
    }

    public String getTitle() {
        return title;
    }

    public String getDescription() {
        return description;
    }

    public boolean isCompleted() {
        return completed;
    }

    public String getOwner() {
        return owner;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getUpdatedAt() {
        return updatedAt;
    }

    public Long getVersion() {
        return version;
    }
}
