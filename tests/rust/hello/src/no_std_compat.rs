use core::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
}

impl Version {
    pub const fn new(major: u16, minor: u16, patch: u16) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    pub const fn is_compatible_with(&self, other: &Version) -> bool {
        self.major == other.major
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::fmt::Write;

    struct StackBuf {
        buf: [u8; 32],
        pos: usize,
    }

    impl StackBuf {
        fn new() -> Self {
            Self {
                buf: [0; 32],
                pos: 0,
            }
        }

        fn as_str(&self) -> &str {
            core::str::from_utf8(&self.buf[..self.pos]).unwrap()
        }
    }

    impl Write for StackBuf {
        fn write_str(&mut self, s: &str) -> fmt::Result {
            let bytes = s.as_bytes();
            let end = self.pos + bytes.len();
            if end > self.buf.len() {
                return Err(fmt::Error);
            }
            self.buf[self.pos..end].copy_from_slice(bytes);
            self.pos = end;
            Ok(())
        }
    }

    #[test]
    fn version_display() {
        let v = Version::new(1, 2, 3);
        let mut buf = StackBuf::new();
        write!(buf, "{v}").unwrap();
        assert_eq!(buf.as_str(), "1.2.3");
    }

    #[test]
    fn version_compatibility() {
        let v1 = Version::new(1, 0, 0);
        let v2 = Version::new(1, 5, 3);
        let v3 = Version::new(2, 0, 0);
        assert!(v1.is_compatible_with(&v2));
        assert!(!v1.is_compatible_with(&v3));
    }

    #[test]
    fn version_equality() {
        let v1 = Version::new(0, 1, 0);
        let v2 = Version::new(0, 1, 0);
        let v3 = Version::new(0, 1, 1);
        assert_eq!(v1, v2);
        assert_ne!(v1, v3);
    }
}
