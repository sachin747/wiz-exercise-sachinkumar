package com.example.securetodo.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;
import org.springframework.security.web.SecurityFilterChain;

import com.example.securetodo.user.UserRepository;

@Configuration
@EnableMethodSecurity
@EnableConfigurationProperties(SecurityUserProperties.class)
public class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http
                .authorizeHttpRequests(authorize -> authorize
                        .requestMatchers("/login", "/signup", "/css/**", "/favicon.ico", "/actuator/health/**")
                        .permitAll()
                        .anyRequest().authenticated())
                .formLogin(form -> form
                        .loginPage("/login")
                        .defaultSuccessUrl("/todos", true)
                        .permitAll())
                .logout(logout -> logout
                        .logoutSuccessUrl("/login?logout")
                        .invalidateHttpSession(true)
                        .deleteCookies("JSESSIONID"))
                .headers(headers -> headers
                        .contentSecurityPolicy(csp -> csp.policyDirectives(
                                "default-src 'self'; "
                                        + "style-src 'self'; "
                                        + "img-src 'self' data:; "
                                        + "form-action 'self'; "
                                        + "frame-ancestors 'none'; "
                                        + "base-uri 'self'"))
                        .frameOptions(frame -> frame.deny()))
                .build();
    }

    @Bean
    PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    UserDetailsService userDetailsService(
            SecurityUserProperties properties, PasswordEncoder passwordEncoder, UserRepository userRepository) {
        var user = User.withUsername(properties.userName())
                .password(passwordEncoder.encode(properties.userPassword()))
                .roles("USER")
                .build();
        var admin = User.withUsername(properties.adminName())
                .password(passwordEncoder.encode(properties.adminPassword()))
                .roles("USER", "ADMIN")
                .build();
        // Same two seeded demo accounts as before.
        var seededUsers = new InMemoryUserDetailsManager(user, admin);

        // Signup (web.SignupController) writes to Mongo, so check there first
        // and fall back to the seeded accounts - keeps COMMANDS.md and the
        // existing demo login flow working.
        // Note the <UserDetails> witness on map(): drop it and javac infers
        // Optional<User> from the map step, which no longer matches what
        // orElseGet's loadUserByUsername supplies (UserDetails).
        return username -> userRepository.findByUsername(username)
                .<UserDetails>map(appUser -> User.withUsername(appUser.getUsername())
                        .password(appUser.getPassword())
                        .roles("USER")
                        .build())
                .orElseGet(() -> seededUsers.loadUserByUsername(username));
    }
}
