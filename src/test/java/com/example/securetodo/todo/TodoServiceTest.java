package com.example.securetodo.todo;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verify;

import java.util.Optional;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class TodoServiceTest {

    @Mock
    private TodoRepository repository;

    @Test
    void createsTrimmedTodoOwnedByCurrentUser() {
        given(repository.save(any(Todo.class))).willAnswer(invocation -> invocation.getArgument(0));
        TodoService service = new TodoService(repository);
        TodoForm form = new TodoForm();
        form.setTitle("  Prepare demo  ");
        form.setDescription("  Show the three tiers  ");

        Todo saved = service.create(form, "alice");

        assertThat(saved.getTitle()).isEqualTo("Prepare demo");
        assertThat(saved.getDescription()).isEqualTo("Show the three tiers");
        assertThat(saved.getOwner()).isEqualTo("alice");
        assertThat(saved.getCreatedAt()).isNotNull();
    }

    @Test
    void doesNotToggleAnotherUsersTodo() {
        given(repository.findByIdAndOwner("todo-1", "alice")).willReturn(Optional.empty());
        TodoService service = new TodoService(repository);

        assertThatThrownBy(() -> service.toggle("todo-1", "alice"))
                .isInstanceOf(TodoNotFoundException.class);
    }

    @Test
    void deletesOnlyAnOwnedTodo() {
        Todo todo = Todo.create("Owned", "", "alice");
        given(repository.findByIdAndOwner("todo-1", "alice")).willReturn(Optional.of(todo));
        TodoService service = new TodoService(repository);

        service.delete("todo-1", "alice");

        ArgumentCaptor<Todo> captor = ArgumentCaptor.forClass(Todo.class);
        verify(repository).delete(captor.capture());
        assertThat(captor.getValue().getOwner()).isEqualTo("alice");
    }
}
