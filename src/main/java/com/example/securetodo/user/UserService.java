package com.example.securetodo.user;

import com.example.securetodo.config.SecurityUserProperties;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
public class UserService {

    private final UserRepository userRepository;
    private final PasswordEncoder passwordEncoder;
    private final SecurityUserProperties seededUsers;

    public UserService(UserRepository userRepository, PasswordEncoder passwordEncoder,
            SecurityUserProperties seededUsers) {
        this.userRepository = userRepository;
        this.passwordEncoder = passwordEncoder;
        this.seededUsers = seededUsers;
    }

    /**
     * Self-service signup: hash the password before it ever touches MongoDB,
     * and reject a username that's already taken -- either by another
     * self-registered account, or by one of the two seeded demo accounts
     * (todo-user / todo-admin). Without that second check, a signup could
     * silently shadow a seeded account, since SecurityConfig looks up
     * MongoDB first.
     */
    public void signUp(String username, String rawPassword) {
        boolean seeded = username.equals(seededUsers.userName()) || username.equals(seededUsers.adminName());
        if (seeded || userRepository.existsByUsername(username)) {
            throw new UsernameTakenException();
        }
        userRepository.save(new AppUser(username, passwordEncoder.encode(rawPassword)));
    }
}
