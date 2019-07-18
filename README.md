# plantuml-markdown-docker

This wraps [mikitex70/plantuml-markdown](https://github.com/mikitex70/plantuml-markdown/)
into a alpine docker container.

# Pull

```
docker pull kerhac/plantuml-markdown
```

# Building

Build docker images.

```
docker build -t kerhac/plantuml-markdown .
```

# Usage
Render `README.md` as html using docker container.

```
cat README.md |docker run --rm --interactive kerhac/plantuml-markdown > README.html
```

# Sample plantuml
---------------
```plantuml
@startuml
Bob -> Alice : hello
@enduml
```

