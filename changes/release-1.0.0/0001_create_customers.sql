CREATE TABLE IF NOT EXISTS customers (
    id          CHAR(36)      NOT NULL DEFAULT (UUID()),
    code        VARCHAR(50)   NOT NULL,
    full_name   VARCHAR(200)  NOT NULL,
    email       VARCHAR(255)  NOT NULL,

    CONSTRAINT pk_customers PRIMARY KEY (id)
);
