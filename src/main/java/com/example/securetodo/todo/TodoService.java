package com.example.securetodo.todo;

import java.util.List;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;

@Service
@PreAuthorize("isAuthenticated()")
public class TodoService {

    private final TodoRepository todoRepository;

    public TodoService(TodoRepository todoRepository) {
        this.todoRepository = todoRepository;
    }

    public List<Todo> listForUser(String username) {
        return todoRepository.findAllByOwnerOrderByCreatedAtDesc(username);
    }

    public Todo create(TodoForm form, String username) {
        String title = form.getTitle().trim();
        String description = form.getDescription() == null ? "" : form.getDescription().trim();
        return todoRepository.save(Todo.create(title, description, username));
    }

    public Todo toggle(String id, String username) {
        Todo todo = findOwnedTodo(id, username);
        todo.toggle();
        return todoRepository.save(todo);
    }

    public void delete(String id, String username) {
        Todo todo = findOwnedTodo(id, username);
        todoRepository.delete(todo);
    }

    private Todo findOwnedTodo(String id, String username) {
        return todoRepository.findByIdAndOwner(id, username)
                .orElseThrow(TodoNotFoundException::new);
    }
}
