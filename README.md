# odomado
Mailing list manager

## Installation

1. Clone the repository

```
github clone https://github.com/erapetti/odomado.git
```

2. Create and initilize a MySQL database:

```
CREATE DATABASE `odomado`;

CREATE TABLE `my_site` (
  `id` varchar(255) DEFAULT NULL,
  `mid` varchar(255) DEFAULT NULL,
  `emailfrom` varchar(255) DEFAULT NULL,
  `subject` longtext DEFAULT NULL,
  `ts` datetime DEFAULT NULL,
  `email` varchar(255) DEFAULT NULL,
  `type` char(4) DEFAULT NULL,
  KEY `email` (`email`)
);

CREATE USER `odomado`@`localhost` IDENTIFIED BY 'pass';

GRANT SELECT, INSERT on omodado.* to `odomado`@`localhost`;
```

3. Create odomado.pm

```
package config {
        $dsn = "DBI:mysql:odomado";
        $username = "odomado";
        $password = 'pass';
	$url = "https://example.com/cgi-bin/odomado.pl";
}

1;
```

4. Add data gatherer task

```
*/5 * * * * /usr/local/bin/odomado_task.pl
```

