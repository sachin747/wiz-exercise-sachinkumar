package com.example.securetodo.web;

import com.example.securetodo.user.SignupForm;
import com.example.securetodo.user.UserService;
import com.example.securetodo.user.UsernameTakenException;
import jakarta.validation.Valid;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.validation.BindingResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class SignupController {

    private final UserService userService;

    public SignupController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/signup")
    String signupForm(Model model) {
        if (!model.containsAttribute("signupForm")) {
            model.addAttribute("signupForm", new SignupForm());
        }
        return "signup";
    }

    @PostMapping("/signup")
    String signup(
            @Valid @ModelAttribute("signupForm") SignupForm signupForm,
            BindingResult bindingResult,
            RedirectAttributes redirectAttributes) {
        if (bindingResult.hasErrors()) {
            return "signup";
        }
        try {
            userService.signUp(signupForm.getUsername(), signupForm.getPassword());
        } catch (UsernameTakenException exception) {
            bindingResult.rejectValue("username", "taken", exception.getMessage());
            return "signup";
        }
        // Deliberately simple: send them to log in with what they just chose,
        // rather than spending code auto-authenticating a session here.
        redirectAttributes.addFlashAttribute("successMessage", "Account created. Sign in below.");
        return "redirect:/login";
    }
}
