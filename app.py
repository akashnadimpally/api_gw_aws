from fastapi import FastAPI, Query
from mangum import Mangum

app = FastAPI()

@app.get("/hello")
def hello(name: str = Query("World")):
    return {"message": f"Hello, {name}!"}

@app.get("/add")
def add(a: int = Query(...), b: int = Query(...)):
    return {"result": a + b}

@app.post("/reverse")
def reverse_text(text: str = Query(...)):
    return {"reversed": text[::-1]}

@app.get("/status")
def status():
    return {"status": "ok"}

@app.get("/lambda/{path:path}")
def catch_all_path(path: str):
    return {"path": path}

handler = Mangum(app)
