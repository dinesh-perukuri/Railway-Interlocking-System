DROP DATABASE IF EXISTS rail_interlocking;
CREATE DATABASE rail_interlocking CHARACTER SET utf8mb4;
USE rail_interlocking;

-- ---------------------------------------------------------------- tables
CREATE TABLE junctions (
    junction_id INT PRIMARY KEY,
    name        VARCHAR(60) NOT NULL UNIQUE
);

CREATE TABLE track_blocks (
    block_id      INT PRIMARY KEY,
    name          VARCHAR(40) NOT NULL UNIQUE,
    from_junction INT NOT NULL,
    to_junction   INT NOT NULL,
    length_m      INT NOT NULL CHECK (length_m > 0),
    status        ENUM('FREE','RESERVED','OCCUPIED','OUT_OF_SERVICE') NOT NULL DEFAULT 'FREE',
    FOREIGN KEY (from_junction) REFERENCES junctions(junction_id),
    FOREIGN KEY (to_junction)   REFERENCES junctions(junction_id),
    CHECK (from_junction <> to_junction)
);

CREATE TABLE trains (
    train_id         INT PRIMARY KEY,
    name             VARCHAR(60) NOT NULL,
    current_block_id INT NULL UNIQUE,            -- one train per block
    FOREIGN KEY (current_block_id) REFERENCES track_blocks(block_id)
);

CREATE TABLE station_staff (
    staff_id    INT PRIMARY KEY AUTO_INCREMENT,
    name        VARCHAR(80) NOT NULL,
    role        ENUM('STATION_MASTER','ASSISTANT_STATION_MASTER','POINTSMAN') NOT NULL,
    junction_id INT NOT NULL,
    shift       ENUM('MORNING','EVENING','NIGHT') NOT NULL,
    phone       VARCHAR(15),
    reports_to  INT NULL,
    FOREIGN KEY (junction_id) REFERENCES junctions(junction_id),
    FOREIGN KEY (reports_to)  REFERENCES station_staff(staff_id)
);

CREATE TABLE route_reservations (
    reservation_id INT PRIMARY KEY AUTO_INCREMENT,
    train_id       INT NOT NULL,
    src_junction   INT NOT NULL,
    dst_junction   INT NOT NULL,
    status         ENUM('ACTIVE','COMPLETED','RELEASED') NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (train_id)     REFERENCES trains(train_id),
    FOREIGN KEY (src_junction) REFERENCES junctions(junction_id),
    FOREIGN KEY (dst_junction) REFERENCES junctions(junction_id)
);

CREATE TABLE route_blocks (
    reservation_id INT NOT NULL,
    seq            INT NOT NULL,
    block_id       INT NOT NULL,
    cleared        BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (reservation_id, seq),
    FOREIGN KEY (reservation_id) REFERENCES route_reservations(reservation_id),
    FOREIGN KEY (block_id)       REFERENCES track_blocks(block_id)
);

CREATE TABLE interlocking_log (
    log_id   INT PRIMARY KEY AUTO_INCREMENT,
    ts       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    train_id INT NULL,
    event    VARCHAR(30) NOT NULL,
    detail   VARCHAR(255)
);

-- -------------------------------------------------------------- triggers
DELIMITER $$

-- Block state machine: FREE -> RESERVED -> OCCUPIED -> FREE, FREE <-> OUT_OF_SERVICE
CREATE TRIGGER trg_block_state BEFORE UPDATE ON track_blocks FOR EACH ROW
BEGIN
    DECLARE msg VARCHAR(200);
    IF NEW.status <> OLD.status THEN
        IF NOT (
            (OLD.status = 'FREE'           AND NEW.status IN ('RESERVED','OUT_OF_SERVICE')) OR
            (OLD.status = 'RESERVED'       AND NEW.status IN ('FREE','OCCUPIED')) OR
            (OLD.status = 'OCCUPIED'       AND NEW.status = 'FREE') OR
            (OLD.status = 'OUT_OF_SERVICE' AND NEW.status = 'FREE')
        ) THEN
            SET msg = CONCAT('Illegal block transition ', OLD.status, ' -> ', NEW.status,
                             ' on ', OLD.name);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
    END IF;
END$$

-- Station staff hierarchy: one master per station; others report to that master
CREATE TRIGGER trg_staff_hierarchy BEFORE INSERT ON station_staff FOR EACH ROW
BEGIN
    DECLARE n INT;
    DECLARE msg VARCHAR(200);
    IF NEW.role = 'STATION_MASTER' THEN
        IF NEW.reports_to IS NOT NULL THEN
            SET msg = 'A Station Master does not report to anyone';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
        SELECT COUNT(*) INTO n FROM station_staff
         WHERE junction_id = NEW.junction_id AND role = 'STATION_MASTER';
        IF n > 0 THEN
            SET msg = 'This station already has a Station Master';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
    ELSE
        SELECT COUNT(*) INTO n FROM station_staff
         WHERE staff_id = NEW.reports_to AND role = 'STATION_MASTER'
           AND junction_id = NEW.junction_id;
        IF n = 0 THEN
            SET msg = 'Assistants/pointsmen must report to the Station Master of the same station';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
    END IF;
END$$

-- One active route per train, and only while the train is outside the network
CREATE TRIGGER trg_reservation_check BEFORE INSERT ON route_reservations FOR EACH ROW
BEGIN
    DECLARE n INT;
    DECLARE blk INT;
    DECLARE msg VARCHAR(200);
    SELECT COUNT(*) INTO n FROM route_reservations
     WHERE train_id = NEW.train_id AND status = 'ACTIVE';
    IF n > 0 THEN
        SET msg = 'Train already has an ACTIVE route reservation';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
    END IF;
    SELECT current_block_id INTO blk FROM trains WHERE train_id = NEW.train_id;
    IF blk IS NOT NULL THEN
        SET msg = 'Train is already on track; it must leave the network first';
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
    END IF;
END$$

-- Route validation: block FREE, route contiguous, starts at the source junction
CREATE TRIGGER trg_route_block_check BEFORE INSERT ON route_blocks FOR EACH ROW
BEGIN
    DECLARE st VARCHAR(20);
    DECLARE mx INT;
    DECLARE prev INT;
    DECLARE n INT;
    DECLARE bname VARCHAR(40);
    DECLARE msg VARCHAR(200);

    SELECT status, name INTO st, bname FROM track_blocks WHERE block_id = NEW.block_id;
    IF st <> 'FREE' THEN
        SET msg = CONCAT('Block ', bname, ' is not free (', st, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
    END IF;

    SELECT MAX(seq) INTO mx FROM route_blocks WHERE reservation_id = NEW.reservation_id;
    IF mx IS NULL THEN
        IF NEW.seq <> 1 THEN
            SET msg = 'Route sequence must start at 1';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
        SELECT COUNT(*) INTO n
          FROM track_blocks b JOIN route_reservations r ON r.reservation_id = NEW.reservation_id
         WHERE b.block_id = NEW.block_id
           AND (b.from_junction = r.src_junction OR b.to_junction = r.src_junction);
        IF n = 0 THEN
            SET msg = CONCAT('First block ', bname, ' does not start at the source junction');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
    ELSE
        IF NEW.seq <> mx + 1 THEN
            SET msg = 'Route sequence has a gap';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
        SELECT block_id INTO prev FROM route_blocks
         WHERE reservation_id = NEW.reservation_id AND seq = mx;
        IF prev = NEW.block_id THEN
            SET msg = 'A block cannot be used twice in one route';
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
        SELECT COUNT(*) INTO n
          FROM track_blocks a JOIN track_blocks b
            ON (a.from_junction IN (b.from_junction, b.to_junction)
             OR a.to_junction   IN (b.from_junction, b.to_junction))
         WHERE a.block_id = prev AND b.block_id = NEW.block_id;
        IF n = 0 THEN
            SET msg = CONCAT('Block ', bname, ' is not connected to the previous block');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
        END IF;
    END IF;
END$$

-- After a block is added to a route, mark it RESERVED
CREATE TRIGGER trg_route_block_reserve AFTER INSERT ON route_blocks FOR EACH ROW
BEGIN
    DECLARE tid INT;
    UPDATE track_blocks SET status = 'RESERVED' WHERE block_id = NEW.block_id;
    SELECT train_id INTO tid FROM route_reservations WHERE reservation_id = NEW.reservation_id;
    INSERT INTO interlocking_log (train_id, event, detail)
    VALUES (tid, 'BLOCK_RESERVED', CONCAT('Block ', NEW.block_id, ' reserved as seq ', NEW.seq));
END$$

-- Train movement policing
CREATE TRIGGER trg_train_move_check BEFORE UPDATE ON trains FOR EACH ROW
BEGIN
    DECLARE rid INT;
    DECLARE new_seq INT;
    DECLARE old_seq INT;
    DECLARE max_seq INT;
    DECLARE blk_status VARCHAR(20);
    DECLARE msg VARCHAR(200);

    IF NOT (NEW.current_block_id <=> OLD.current_block_id) THEN
        SELECT MAX(reservation_id) INTO rid FROM route_reservations
         WHERE train_id = NEW.train_id AND status = 'ACTIVE';

        IF NEW.current_block_id IS NOT NULL THEN
            IF rid IS NULL THEN
                SET msg = 'Train has no active route reservation';
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
            END IF;
            SELECT MAX(seq) INTO new_seq FROM route_blocks
             WHERE reservation_id = rid AND block_id = NEW.current_block_id;
            IF new_seq IS NULL THEN
                SET msg = 'Target block is not part of the reserved route';
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
            END IF;
            IF OLD.current_block_id IS NULL THEN
                IF new_seq <> 1 THEN
                    SET msg = 'Train must enter the network at the first block of its route';
                    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
                END IF;
            ELSE
                SELECT MAX(seq) INTO old_seq FROM route_blocks
                 WHERE reservation_id = rid AND block_id = OLD.current_block_id;
                IF old_seq IS NULL OR new_seq <> old_seq + 1 THEN
                    SET msg = 'Train must advance one block at a time along its route';
                    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
                END IF;
            END IF;
            SELECT status INTO blk_status FROM track_blocks WHERE block_id = NEW.current_block_id;
            IF blk_status <> 'RESERVED' THEN
                SET msg = CONCAT('Block is not clear for movement (status ', blk_status, ')');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
            END IF;
        ELSE
            IF rid IS NOT NULL AND OLD.current_block_id IS NOT NULL THEN
                SELECT MAX(seq) INTO old_seq FROM route_blocks
                 WHERE reservation_id = rid AND block_id = OLD.current_block_id;
                SELECT MAX(seq) INTO max_seq FROM route_blocks WHERE reservation_id = rid;
                IF old_seq IS NULL OR old_seq <> max_seq THEN
                    SET msg = 'Train can leave only from the last block of its route';
                    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = msg;
                END IF;
            END IF;
        END IF;
    END IF;
END$$

-- Train movement side effects: free/occupy blocks, mark cleared, complete route
CREATE TRIGGER trg_train_move_apply AFTER UPDATE ON trains FOR EACH ROW
BEGIN
    IF NOT (NEW.current_block_id <=> OLD.current_block_id) THEN
        IF OLD.current_block_id IS NOT NULL THEN
            UPDATE track_blocks SET status = 'FREE' WHERE block_id = OLD.current_block_id;
            UPDATE route_blocks rb
              JOIN route_reservations r ON r.reservation_id = rb.reservation_id
               SET rb.cleared = TRUE
             WHERE r.train_id = NEW.train_id AND r.status = 'ACTIVE'
               AND rb.block_id = OLD.current_block_id;
        END IF;
        IF NEW.current_block_id IS NOT NULL THEN
            UPDATE track_blocks SET status = 'OCCUPIED' WHERE block_id = NEW.current_block_id;
            INSERT INTO interlocking_log (train_id, event, detail)
            VALUES (NEW.train_id, 'MOVED', CONCAT('Train entered block ', NEW.current_block_id));
        ELSE
            UPDATE route_reservations SET status = 'COMPLETED'
             WHERE train_id = NEW.train_id AND status = 'ACTIVE';
            INSERT INTO interlocking_log (train_id, event, detail)
            VALUES (NEW.train_id, 'LEFT_NETWORK', 'Train left the network');
        END IF;
    END IF;
END$$

DELIMITER ;

-- ------------------------------------------- seed: 15 stations
INSERT INTO junctions (junction_id, name) VALUES
 (1,'Secunderabad Jn'), (2,'Sitaphalmandi'),  (3,'Jamia Osmania'),
 (4,'Hyderabad Nampally'), (5,'Lakdikapul'),  (6,'Khairatabad'),
 (7,'Necklace Road'),  (8,'Begumpet'),        (9,'Sanath Nagar'),
 (10,'Fateh Nagar'),   (11,'Borabanda'),      (12,'Hi-Tech City'),
 (13,'Hafeezpet'),     (14,'Chandanagar'),    (15,'Lingampalli');

-- ------------------------------------------- seed: main line + 3 loops
INSERT INTO track_blocks (block_id, name, from_junction, to_junction, length_m, status) VALUES
 (1 ,'SC-STPD',  1, 2 , 2100,'FREE'),
 (2 ,'STPD-JMO', 2, 3 , 1800,'FREE'),
 (3 ,'JMO-NMPL', 3, 4 , 2400,'FREE'),
 (4 ,'NMPL-LKPL',4, 5 , 1500,'FREE'),
 (5 ,'LKPL-KQD', 5, 6 , 1700,'FREE'),
 (6 ,'KQD-NLRD', 6, 7 , 2000,'FREE'),
 (7 ,'NLRD-BMT', 7, 8 , 2600,'FREE'),
 (8 ,'BMT-SNNR', 8, 9 , 1900,'FREE'),
 (9 ,'SNNR-FNB', 9, 10, 2200,'FREE'),
 (10,'FNB-BORA', 10,11, 1600,'FREE'),
 (11,'BORA-HTCY',11,12, 2800,'FREE'),
 (12,'HTCY-HFZ', 12,13, 2300,'FREE'),
 (13,'HFZ-CDNR', 13,14, 1500,'FREE'),
 (14,'CDNR-LPI', 14,15, 2000,'FREE'),
 (15,'NMPL-KQD-LOOP',  4, 6 , 3300,'FREE'),
 (16,'BMT-FNB-LOOP',   8, 10, 4300,'FREE'),
 (17,'HTCY-CDNR-LOOP', 12,14, 4000,'FREE');

-- ------------------------------------------- seed: 5 Telugu trains
INSERT INTO trains (train_id, name, current_block_id) VALUES
 (1,'12727 Godavari Express',     NULL),
 (2,'17406 Krishna Express',      NULL),
 (3,'17220 Machilipatnam Express',NULL),
 (4,'12269 Duranto Express',      NULL),
 (5,'22708 Humsafar Express',     NULL);

-- ------------------------------------------- seed: station staff
INSERT INTO station_staff (staff_id, name, role, junction_id, shift, phone, reports_to) VALUES
 (1 ,'P. Dinesh',  'STATION_MASTER',           1 ,'MORNING','9618539258',NULL),
 (2 ,'P. Srinivas Rao',    'ASSISTANT_STATION_MASTER', 1 ,'MORNING','9000000002',1),
 (3 ,'M. Lakshmi',         'ASSISTANT_STATION_MASTER', 1 ,'NIGHT'  ,'9000000003',1),
 (4 ,'Y. Ranjith',   'STATION_MASTER',           4 ,'MORNING','9000000003',NULL),
 (5 ,'B. Anitha Reddy',    'ASSISTANT_STATION_MASTER', 4 ,'EVENING','9000000005',4),
 (6 ,'S. Ramesh',          'POINTSMAN',                4 ,'NIGHT'  ,'9000000006',4),
 (7 ,'D. Rasool','STATION_MASTER',           8 ,'MORNING','8561423597',NULL),
 (8 ,'V. Swathi',          'ASSISTANT_STATION_MASTER', 8 ,'EVENING','9000000008',7),
 (9 ,'D. Dipak',          'STATION_MASTER',           12,'MORNING','9547563217',NULL),
 (10,'R. Kavitha',         'ASSISTANT_STATION_MASTER', 12,'NIGHT'  ,'9000000010',9),
 (11,'P. Abhii7',  'STATION_MASTER',           15,'MORNING','9000000011',NULL),
 (12,'A. Harika',          'ASSISTANT_STATION_MASTER', 15,'EVENING','9000000012',11),
 (13,'J. Mahesh',          'POINTSMAN',                15,'NIGHT'  ,'9000000013',11);