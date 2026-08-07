package com.example.securetodo.todo;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public class TodoForm {

    @NotBlank(message = "Give the todo a title")
    @Size(max = 120, message = "Keep the title under 120 characters")
    private String title;

    @Size(max = 500, message = "Keep the details under 500 characters")
    private String description;

    public String getTitle() {
        return title;
    }

    public void setTitle(String title) {
        this.title = title;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }
}
