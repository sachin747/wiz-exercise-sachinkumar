package com.example.securetodo.web;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verify;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrlPattern;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.view;

import java.util.List;

import com.example.securetodo.todo.TodoForm;
import com.example.securetodo.todo.TodoService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(TodoController.class)
class TodoControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private TodoService todoService;

//    @Test
//    void redirectsAnonymousUserToLogin() throws Exception {
//        mockMvc.perform(get("/todos"))
//                .andExpect(status().is3xxRedirection())
//                .andExpect(redirectedUrlPattern("**/login"));
//    }

    @Test
    @WithMockUser(username = "alice")
    void rendersTodosForAuthenticatedUser() throws Exception {
        given(todoService.listForUser("alice")).willReturn(List.of());

        mockMvc.perform(get("/todos"))
                .andExpect(status().isOk())
                .andExpect(view().name("todos"));
    }

    @Test
    @WithMockUser(username = "alice")
    void rejectsCreateWithoutCsrfToken() throws Exception {
        mockMvc.perform(post("/todos").param("title", "Prepare demo"))
                .andExpect(status().isForbidden());
    }

    @Test
    @WithMockUser(username = "alice")
    void createsTodoWithCsrfToken() throws Exception {
        mockMvc.perform(post("/todos")
                        .with(csrf())
                        .param("title", "Prepare demo")
                        .param("description", "Show all three tiers"))
                .andExpect(status().is3xxRedirection());

        verify(todoService).create(any(TodoForm.class), eq("alice"));
    }
}
