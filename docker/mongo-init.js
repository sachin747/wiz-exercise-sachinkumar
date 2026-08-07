db = db.getSiblingDB("todo");
db.createUser({
    user: "todo_app",
    pwd: "todo_dev_password",
    roles: [{ role: "readWrite", db: "todo" }]
});
