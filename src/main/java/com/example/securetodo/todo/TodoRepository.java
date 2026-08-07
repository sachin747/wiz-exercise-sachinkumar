package com.example.securetodo.todo;

import java.util.List;
import java.util.Optional;

import org.springframework.data.mongodb.repository.MongoRepository;

public interface TodoRepository extends MongoRepository<Todo, String> {

    List<Todo> findAllByOwnerOrderByCreatedAtDesc(String owner);

    Optional<Todo> findByIdAndOwner(String id, String owner);
}
