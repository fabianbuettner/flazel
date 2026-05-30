fn main() {
    let mut buf = itoa::Buffer::new();
    println!("itoa: {}", buf.format(42u32));
}
