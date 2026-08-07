package com.example.securetodo.todo;

public class TodoNotFoundException extends RuntimeException {

    public TodoNotFoundException() {
        super("Todo not found");
    }
}
