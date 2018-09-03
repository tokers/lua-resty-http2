# Table of Contents

* [FRAME](#frame)
  * [FRAME HEADER](#frame-header)
  * [PRIORITY](#priority-frame)
  * [RST](#rst)
  * [SETTINGS](#settings)
  * [PING](#ping)
  * [GOAWAY](#goaway)
  * [WINDOW_UPDATE](#window_update)
  * [HEADERS](#headers)
  * [RST_STREAM](#rst_stream)
  * [DATA](#data)
* [STREAM](#stream)
  * [STREAM STATE](#stream-state)
* [HPACK](#hpack)
  * [Literal Header Field with Incremental Indexing](#literal-header-field-with-incremental-indexing)
  * [Literal Header Field with Incremental Indexing](#literal-header-field-with-incremental-indexing)
    * [Indexed Name](#indexed-name)
    * [New Name](#new-name)
  * [Literal Header Field without Indexing](#literal-header-field-without-indexing)
    * [Indexed Name](#indexed-name)
    * [New Name](#new-name)
  * [Literal Header Field Never Indexed](#literal-header-field-never-indexed)
    * [Indexed Name](#indexed-name)
    * [New Name](#new-name)
  * [Dynamic Table Size Update](dynamic-table-size-update)

# FRAME

## FRAME HEADER

```
+-----------------------------------------------+
|                   Length (24)                 |
+---------------+---------------+---------------+
|    Type (8)   |   Flags (8)   |
+-+-------------+---------------+---------------+
|R|             Stream Identifier (31)          |
+=+=============================================+
|               Frame Payload (0...)          ...
+-----------------------------------------------+
```

## PRIORITY

```
+-+-------------------------------------------------------------+
|E|                   Stream Dependency (31)                    |
+-+-------------+-----------------------------------------------+
|   Weight (8)  |
+-+-------------+
```

## RST
```
+---------------------------------------------------------------+
|                           Error Code (32)                     |
+---------------------------------------------------------------+
```

## SETTINGS

```
+-------------------------------+
|        Identifier (16)        |
+-------------------------------+-------------------------------+
|                           Value (32)                          |
+---------------------------------------------------------------+
```

## PING

```
+---------------------------------------------------------------+
|                                                               |
|                         Opaque Data (64)                      |
|                                                               |
+---------------------------------------------------------------+
```

## GOAWAY

```
+-+-------------------------------------------------------------+
|R|                     Last-Stream-ID (31)                     |
+-+-------------------------------------------------------------+
|                        Error Code (32)                        |
+---------------------------------------------------------------+
|                      Additional Debug Data (*)                |
+---------------------------------------------------------------+
```

## WINDOW_UPDATE

```
+-+-------------------------------------------------------------+
|R|                     Window Size Increment (31)              |
+-+-------------------------------------------------------------+
```

## HEADERS

```
+---------------+
|Pad Length? (8)|
+-+-------------+-----------------------------------------------+
|E|                     Stream Dependency? (31)                 |
+-+-------------+-----------------------------------------------+
|  Weight? (8)  |
+-+-------------+-----------------------------------------------+
|                       Header Block Fragment (*)             ...
+---------------------------------------------------------------+
|                               Padding (*)                   ...
+---------------------------------------------------------------+
```

## DATA

```
+---------------+
|Pad Length? (8)|
+---------------+-----------------------------------------------+
|                          Data (*)                           ...
+---------------------------------------------------------------+
|                         Padding (*)                         ...
+---------------------------------------------------------------+
```

## RST_STREAM

```
+---------------------------------------------------------------+
|                           Error Code (32)                     |
+---------------------------------------------------------------+
```

# STREAM

## STREAM STATE

```
                                    +--------+
                          send PP   |        | recv PP
                          ,---------|  idle  |---------.
                         /          |        |          \
                        v           +--------+           v
                  +----------+          |           +----------+
                  |          |          |  send H / |          |
          ,-------| reserved |          |  recv H   | reserved |------.
          |       | (local)  |          |           | (remote) |      |
          |       +----------+          v           +----------+      |
          |             |           +--------+           |            |
          |             |  recv ES  |        |  send ES  |            |
          |      send H |   ,-------|  open  |-------.   | recv H     |
          |             |  /        |        |        \  |            |
          |             v v         +--------+         v v            |
          |   +----------+              |              +----------+   |
          |   |   half   |              |              |   half   |   |
          |   |  closed  |              |     send R / |  closed  |   |
          |   | (remote) |              |     recv R   |  (local) |   |
          |   +----------+              |              +----------+   |
          |        |                    |                   |         |
          |        | send ES /          |         recv ES / |         |
          |        | send R /           v         send R /  |         |
          |        | recv R         +--------+    recv R    |         |
          |send R /‘--------------->|        |<-------------’ send R /|
          |recv R                   | closed |                recv R  |
          ‘------------------------>|        |<-----------------------’
                                    +--------+
```

* send: endpoint sends this frame 
* recv: endpoint receives this frame
* H: HEADERS frame (with implied CONTINUATIONs)
* PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
* ES: END_STREAM flag
* R: RST_STREAM frame

# HPACK

## Indexed Header Field Representation

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 1 |       Index (7+)          |
+---+---------------------------+
```

## Literal Header Field with Incremental Indexing

### Indexed Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 1 |      Index (6+)       |
+---+---+-----------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
| Value String (Length octets)  |
+-------------------------------+
```

### New Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 1 |          0            |
+---+---+-----------------------+
| H |       Name Length (7+)    |
+---+---------------------------+
|  Name String (Length octets)  |
+---+---------------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
|  Value String (Length octets) |
+-------------------------------+
```

## Literal Header Field without Indexing

### Indexed Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 0 |   Index (4+)  |
+---+---+-----------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
|  Value String (Length octets) |
+-------------------------------+
```

### New Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 0 |        0      |
+---+---+-----------------------+
| H |      Name Length (7+)     |
+---+---------------------------+
|  Name String (Length octets)  |
+---+---------------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
|  Value String (Length octets) |
+-------------------------------+
```

## Literal Header Field Never Indexed

### Indexed Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 1 |  Index (4+)   |
+---+---+-----------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
|  Value String (Length octets) |
+-------------------------------+
```

### New Name

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 0 | 1 |       0       |
+---+---+-----------------------+
| H |      Name Length (7+)     |
+---+---------------------------+
|  Name String (Length octets)  |
+---+---------------------------+
| H |     Value Length (7+)     |
+---+---------------------------+
|  Value String (Length octets) |
+-------------------------------+
```

## Dynamic Table Size Update

```
  0   1   2   3   4   5   6   7
+---+---+---+---+---+---+---+---+
| 0 | 0 | 1 |   Max size (5+)   |
+---+---------------------------+
```
