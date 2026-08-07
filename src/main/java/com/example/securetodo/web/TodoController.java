package com.example.securetodo.web;

import java.security.Principal;

import com.example.securetodo.todo.TodoForm;
import com.example.securetodo.todo.TodoNotFoundException;
import com.example.securetodo.todo.TodoService;
import jakarta.validation.Valid;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.validation.BindingResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class TodoController {

    private final TodoService todoService;

    public TodoController(TodoService todoService) {
        this.todoService = todoService;
    }

    @GetMapping("/")
    String home() {
        return "redirect:/todos";
    }

    @GetMapping("/todos")
    String todos(Model model, Principal principal) {
        if (!model.containsAttribute("todoForm")) {
            model.addAttribute("todoForm", new TodoForm());
        }
        populatePage(model, principal.getName());
        return "todos";
    }

    @PostMapping("/todos")
    String create(
            @Valid @ModelAttribute("todoForm") TodoForm todoForm,
            BindingResult bindingResult,
            Model model,
            Principal principal,
            RedirectAttributes redirectAttributes) {
        if (bindingResult.hasErrors()) {
            populatePage(model, principal.getName());
            return "todos";
        }

        todoService.create(todoForm, principal.getName());
        redirectAttributes.addFlashAttribute("successMessage", "Todo added");
        return "redirect:/todos";
    }

    @PostMapping("/todos/{id}/toggle")
    String toggle(@PathVariable String id, Principal principal, RedirectAttributes redirectAttributes) {
        try {
            todoService.toggle(id, principal.getName());
            redirectAttributes.addFlashAttribute("successMessage", "Todo updated");
        } catch (TodoNotFoundException exception) {
            redirectAttributes.addFlashAttribute("errorMessage", "That todo no longer exists");
        }
        return "redirect:/todos";
    }

    @PostMapping("/todos/{id}/delete")
    String delete(@PathVariable String id, Principal principal, RedirectAttributes redirectAttributes) {
        try {
            todoService.delete(id, principal.getName());
            redirectAttributes.addFlashAttribute("successMessage", "Todo deleted");
        } catch (TodoNotFoundException exception) {
            redirectAttributes.addFlashAttribute("errorMessage", "That todo no longer exists");
        }
        return "redirect:/todos";
    }

    private void populatePage(Model model, String username) {
        model.addAttribute("todos", todoService.listForUser(username));
        model.addAttribute("username", username);
    }
}
